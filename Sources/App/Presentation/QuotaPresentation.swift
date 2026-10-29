import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import TrafficCore
#endif

enum Magpie {
    static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }
    static let background = color(0xF4F4F6, 0x1A1A1E)
    static let surface = color(0xFFFFFF, 0x232327)
    static let secondary = color(0xF9F9FB, 0x1F1F23)
    static let pill = color(0xEBEBF0, 0x2D2D33)
    static let accent = color(0x4F46E5, 0xA5B4FC)
    static let warning = color(0xB45309, 0xF2B544)
    static let warningSurface = color(0xFBF0DF, 0x3F3220)
    static let danger = color(0xBC3D3D, 0xF28B82)
    static let line = Color.primary.opacity(0.07)
    static let navigation = Color(nsColor: .darkGray)
}

enum QuotaRisk { case normal, warning, danger
    var color: Color { switch self { case .normal: return .primary; case .warning: return Magpie.warning; case .danger: return Magpie.danger } }
}

struct MenuQuotaPresentation {
    let subscription: Subscription?
    var risk: QuotaRisk {
        guard let info = subscription, info.total > 0, let remaining = info.remaining else { return .normal }
        if Double(remaining) <= Double(info.total) * 0.2 { return .danger }
        if Double(remaining) <= Double(info.total) * 0.5 { return .warning }
        return .normal
    }
    var remainingFraction: Double? {
        guard let info = subscription, info.total > 0 else { return nil }
        return max(0, min(1, 1 - info.fraction))
    }
    var barColor: Color { risk == .normal ? Magpie.accent : risk.color }
}

struct ResetPresentation {
    let next: Date?
    let value: String
    let detail: String

    init(rule: ResetRule, at date: Date, displayTimeZone: TimeZone? = nil) {
        guard rule.kind != .none else {
            next = nil; value = "未设置"
            detail = "未设置重置规则；不根据到期时间或套餐名称推断。"
            return
        }
        guard (try? rule.validate()) != nil else {
            next = nil; value = "规则无效"
            detail = "重置日期、时间或时区无效，请检查已有配置。"
            return
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = rule.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let zone = rule.timeZoneID
        guard let event = rule.window(at: date).next else {
            next = nil; value = "计划已过"
            detail = "已设置的重置时间 \(formatter.string(from: rule.anchor))（\(zone)）已过，未安排下次重置；实际用量以服务端同步为准。"
            return
        }
        next = event
        let fullDate = formatter.string(from: event)
        if let displayTimeZone { formatter.timeZone = displayTimeZone }
        let displayFullDate = formatter.string(from: event)
        formatter.dateFormat = "MM-dd HH:mm"
        value = formatter.string(from: event) + (displayTimeZone == nil ? "" : " · 本地")
        let day = rule.kind == .billing ? rule.calendar.component(.day, from: rule.anchor) : rule.day
        let schedule: String
        switch rule.kind {
        case .monthly: schedule = "每月\(day)日（短月取月末）"
        case .billing: schedule = "每月按购买日\(day)日（短月取月末）"
        case .once: schedule = "指定的一次性计划"
        case .none: schedule = "未设置"
        }
        let localDetail = displayTimeZone.map { "；本地时间 \(displayFullDate)（\($0.identifier)）" } ?? ""
        detail = "按已设置规则：\(schedule)，预计 \(fullDate)（规则时区 \(zone)）\(localDetail)；实际用量以服务端同步为准。"
    }
}

@MainActor
struct BasicQuotaPresentation {
    let model: MonitorModel
    var risk: QuotaRisk {
        if model.latest?.subscription.remaining == 0 || model.expired { return .danger }
        return model.lowBalance ? .warning : .normal
    }
    var needsAttention: Bool {
        risk != .normal || model.error != nil || model.stale || model.storageBlocked || model.latest?.subscription.remaining == nil
    }
    var status: String? {
        if !model.enabled { return "同步已暂停" }
        if model.latest?.subscription.remaining == 0 { return "流量已用尽" }
        if model.expired { return "套餐已到期" }
        if model.latest == nil { return "等待首次同步" }
        if model.stale { return "读数待更新" }
        if model.latest?.subscription.total == 0 { return "总额未知，无法计算余量" }
        if model.lowBalance { return "余量偏低" }
        return nil
    }
}

@MainActor
struct QuotaPresentation {
    let model: MonitorModel
    // One render reads risk, title, detail and accessibility labels repeatedly.
    // Keep a single forecast snapshot instead of rescanning history per field.
    let result: ForecastResult
    init(model: MonitorModel) {
        self.model = model
        result = model.forecastResult
    }
    var risk: QuotaRisk {
        if let remaining = model.latest?.subscription.remaining, remaining == 0 { return .danger }
        if model.expired { return .danger }
        if model.enabled, let estimate = result.estimate, estimate.boundary != nil, estimate.runsOutBeforeBoundary { return .danger }
        return model.lowBalance ? .warning : .normal
    }
    var needsAttention: Bool { risk != .normal || model.error != nil || model.stale || model.storageBlocked }
    var title: String {
        if model.latest?.subscription.remaining == 0 { return "可用流量已用尽" }
        if model.expired { return "套餐已到期" }
        if !model.enabled { return "同步已暂停" }
        if model.latest == nil { return model.hasURL ? "等待首次同步" : "添加订阅，开始记录" }
        if result.reason == .unlimited { return "套餐总量未知" }
        switch result.diagnostic {
        case .synchronizationFailed: return "同步失败 · 预测暂停"
        case .synchronizing: return "正在同步 · 预测暂停"
        case .pendingVerification: return "读数待核对 · 预测暂停"
        case .resetRuleChanged: return "重置规则待核对"
        case .missingReset: return "设置重置周期"
        case .expiryBeforeReset: return "到期不晚于重置 · 预测暂停"
        case .zeroGrowth: return "尚未观测到用量增长"
        case .futureReading: return "读数时间异常 · 预测暂停"
        default: break
        }
        if result.reason == .insufficient { return model.lowBalance ? "余量偏低 · 预测数据不足" : "正在积累预测数据" }
        if result.reason == .stale { return model.lowBalance ? "余量偏低 · 预测暂停" : "数据已过期 · 预测暂停" }
        if result.reason == .awaitingReset { return "等待同步确认重置" }
        if let e = result.estimate {
            if e.dailyBytes == 0 { return model.lowBalance ? "余量偏低 · 暂不推算用尽时间" : "暂不推算用尽时间" }
            if e.boundary == nil { return "设置重置周期" }
            if e.runsOutBeforeBoundary { return "预计撑不到\(e.boundaryKind == .reset ? "重置" : "到期")" }
            return "\(model.lowBalance ? "余量偏低 · " : "")预计可用至\(e.boundaryKind == .reset ? "重置" : "到期")"
        }
        return "预测暂不可用"
    }
    var detail: String {
        if !model.enabled { return "重新启用后继续采样，历史与余量保留。" }
        if model.latest?.subscription.remaining == 0 { return "等待重置或更新套餐。" }
        switch result.diagnostic {
        case .insufficientHistory:
            return "已观察 \(String(format: "%.1f", result.observedSeconds / 3600)) 小时 · \(result.sampleCount) 次读数 · \(result.eligibleDays) 个日期；需 72 小时、4 次、3 个日期。"
        case .zeroGrowth: return "连续观测中没有增长，暂不推算未来消耗或承诺够用。"
        case .expiryBeforeReset: return "已知到期时间不晚于下次重置，不作可用至重置的判断。"
        case .resetRuleChanged: return "新规则等待有效读数核对；生效前的历史统计保留。"
        case .missingReset: return "设置有效的下次重置时间后，才能估计届时余量。"
        case .futureReading: return "读数时间晚于当前时间，请检查系统时间后重新同步。"
        default: break
        }
        if result.reason == .stale { return "成功同步后更新预测；旧读数仍保留。" }
        if result.reason == .awaitingReset { return "不会根据计划时间自动补满余额。" }
        if result.reason == .unlimited { return "服务端未提供可确定的总量，隐藏余量比例。" }
        if let e = result.estimate {
            if e.dailyBytes == 0 { return "有效日内未观测到消耗。" }
            if let boundary = e.boundary {
                if e.runsOutBeforeBoundary, let exhaustion = e.exhaustion {
                    return "比 \(NativeFormat.shortDate(boundary)) \(e.boundaryKind == .reset ? "重置" : "到期")提前 \(String(format: "%.1f", boundary.timeIntervalSince(exhaustion) / 86400)) 天"
                }
                return "\(NativeFormat.shortDate(boundary)) \(e.boundaryKind == .reset ? "重置" : "到期")时预计剩余"
            }
            return "设置周期后，查看余量能否撑到重置。"
        }
        return "成功同步后开始记录用量。"
    }
    var value: String? {
        guard model.enabled, let e = result.estimate, e.boundary != nil, e.dailyBytes > 0 else { return nil }
        if e.runsOutBeforeBoundary { return e.exhaustion.map(NativeFormat.shortDate) }
        return e.remainingAtBoundary.map { "≈ \(NativeFormat.amount($0, unit: model.trafficUnit))" }
    }
    var help: String {
        let e = result.estimate
        return [e.map { "日均约 \(NativeFormat.amount($0.dailyBytes, unit: model.trafficUnit)) · 实际观测 \(String(format: "%.1f", result.observedSeconds / 3600)) 小时" },
                "使用最近 7×24 小时内最新的连续可比较读数：跨度至少 72 小时、至少 4 次读数、覆盖至少 3 个统计日期；包括今天的有效读数。",
                "日均按实际增长与经过秒数计算；不插值、不补零。相邻读数超过 24 小时、计划重置、分量回退、额度或规则变更会断开预测序列。",
                "统计时区：\(model.calendar.timeZone.identifier)。跨日无法分配的差额保留在完整区间，不摊到某一天。",
                "纵轴按余量变化独立缩放，各机场的时间跨度不同，曲线斜率不宜直接比较。",
                model.error != nil ? "同步失败：上次成功的读数和历史保留，当前预测暂停。" : nil]
            .compactMap { $0 }.joined(separator: "\n\n")
    }
    var compactTitle: String {
        if risk == .danger, model.enabled, !model.expired, model.latest?.subscription.remaining != 0,
           let estimate = result.estimate, estimate.runsOutBeforeBoundary, let date = estimate.exhaustion {
            return "预计 \(NativeFormat.shortDate(date)) 用尽"
        }
        return title
    }
    var compactValueLabel: String? {
        guard let value else { return nil }
        if risk == .danger { return detail }
        return "\(result.estimate?.boundaryKind == .expiry ? "到期" : "重置")时约剩 " + value.replacingOccurrences(of: "≈ ", with: "")
    }
}

enum NativeFormat {
    // DateFormatter setup is expensive when every record row and AX label
    // formats the same date. These immutable formatters follow the local zone.
    private static let dayFormatter = formatter("yyyy-MM-dd")
    private static let timeFormatter = formatter("HH:mm")
    private static func formatter(_ format: String) -> DateFormatter {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = .autoupdatingCurrent
        value.dateFormat = format
        return value
    }
    static func percentage(_ fraction: Double, decimals: Int = 1) -> String {
        guard fraction.isFinite else { return "—" }
        let text = String(format: "%.*f", min(3, max(0, decimals)), min(1, max(0, fraction)) * 100)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + "%"
    }
    static func dayStatus(_ row: DailyUsage) -> String {
        if Calendar.current.isDateInToday(row.date) { return "当日未结束" }
        if row.summary.intervals == 0 { return "缺少记录" }
        return row.coverage < 0.8 ? "记录不完整" : "有效记录"
    }
    static func amount(_ bytes: Double, unit: TrafficUnit = .gb) -> String {
        guard bytes.isFinite, bytes >= 0, bytes < Double(UInt64.max) else { return "—" }
        return unit.menuText(UInt64(bytes))
    }
    static func shortDate(_ date: Date) -> String { date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).locale(Locale(identifier: "zh_CN"))) }
    static func day(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }
    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }
}

