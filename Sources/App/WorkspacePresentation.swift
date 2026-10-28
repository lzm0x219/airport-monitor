import Foundation
#if SWIFT_PACKAGE
import TrafficCore
#endif

/// Read-only projection of one source. Never applies the current source's rule
/// to an older ledger or combines records across a subscription identity change.
struct SourceHistoryPresentation {
    let report: UsageReport?
    init(source: SourceRecord, calendar: Calendar) {
        guard let first = source.ledger.samples.first, let last = source.ledger.samples.last,
              let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last.date)) else {
            report = nil
            return
        }
        report = source.ledger.usageReport(
            in: DateInterval(start: calendar.startOfDay(for: first.date), end: end), calendar: calendar,
            rule: source.resetRule,
            revisions: source.resetRevisions.map { StatisticsRuleRevision(effectiveAt: $0.effectiveAt, rule: $0.rule) })
    }
}

/// Main-window language; deliberately independent of the protected menu panel.
@MainActor
struct WorkspacePresentation {
    let model: MonitorModel
    var usesOldReading: Bool {
        model.latest != nil && (model.error != nil || model.stale || model.busy || !model.enabled ||
            model.archived || model.syncPending || model.linkVerificationPending || model.storageBlocked)
    }
    var status: String {
        if model.storageBlocked { return "存储异常" }
        if model.busy { return "同步中" }
        if !model.enabled { return "已暂停" }
        if model.error != nil { return "同步失败" }
        if model.syncPending || model.linkVerificationPending { return "待核对" }
        if model.latest == nil { return "待同步" }
        if let latest = model.latest, latest.date > model.referenceDate { return "读数时间异常" }
        if model.stale { return requestLimitUntil == nil ? "可刷新" : "限频等待" }
        return "同步正常"
    }
    var statusDetail: String {
        if model.storageBlocked { return "本地数据受保护，暂不写入新读数。请在设置中查看恢复方式。" }
        if model.busy { return "正在读取订阅；成功前仍显示上次读数。" }
        if !model.enabled { return "自动同步与本机场通知已暂停，仍可手动同步一次。" }
        if let error = model.error { return error + " 上次成功的读数与历史保留。" + refreshTimeDetail }
        if model.syncPending || model.linkVerificationPending { return "等待成功同步核对，当前显示上次读数；保留已有历史。" }
        if let latest = model.latest, latest.date > model.referenceDate {
            return "读数晚于设备当前时间，请先核对设备时间；保留上次记录。"
        }
        if model.stale {
            if requestLimitUntil != nil {
                return "当前显示上次读数，不是实时余额。同一订阅至少间隔72小时，正在正常等待。" + refreshTimeDetail
            }
            return "当前显示上次读数，不是实时余额。已到最早刷新时间，可手动刷新；自动同步继续按所选周期安排。"
        }
        if let waiting = model.requestWaitingMessage { return waiting + " 当前读数与历史保留。" }
        return model.latest == nil ? "首次成功同步只建立基线，不补造此前的用量。" : "显示最近一次成功读取的数据。"
    }
    /// A known lower bound for display only. The persistent URL gate remains
    /// authoritative, including attempts by other profiles sharing the URL.
    private var requestLimitUntil: Date? {
        let observed = (model.syncAttempts.map(\.date) + [model.latest?.date].compactMap { $0 }).max()
        let until = [model.requestAvailableAt, observed?.addingTimeInterval(SubscriptionRefreshPolicy.minimumInterval)]
            .compactMap { $0 }.max()
        return until.flatMap { $0 > model.referenceDate ? $0 : nil }
    }
    private var refreshTimeDetail: String {
        guard let until = requestLimitUntil else { return "" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return " 最早可刷新：\(formatter.string(from: until))（本地时间）；实际请求仍由限频检查决定。"
    }
    var successTime: String {
        guard let date = model.latest?.date else { return "尚未更新" }
        let formatter = DateFormatter(); formatter.dateFormat = "MM/dd HH:mm"
        return formatter.string(from: date)
    }
    static func removalDetail(profile: AirportProfile, active: [AirportProfile], primary: UUID?) -> String {
        let base = "停止同步和提醒，保留配置与全部历史，可从已移除机场恢复。"
        guard primary == profile.id else { return base }
        let remaining = active.filter { $0.id != profile.id }
        if let next = remaining.first(where: { $0.enabled }) ?? remaining.first {
            return base + " 主力将交给“\(next.name)”。"
        }
        return base + " 当前没有其他机场，菜单栏将暂不显示机场读数。"
    }
}
