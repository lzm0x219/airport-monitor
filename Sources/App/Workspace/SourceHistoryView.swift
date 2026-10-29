import SwiftUI

struct SourceHistoryView: View {
    @ObservedObject var workspace: AirportWorkspace
    let profile: AirportProfile
    @Environment(\.dismiss) private var dismiss
    @FocusState private var closeFocused: Bool
    var body: some View {
        let sources = workspace.sourceHistory(for: profile)
        let model = workspace.model(for: profile)
        let initial = sources.last(where: { $0.endedAt != nil })?.id ?? sources.last?.id
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("来源历史").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(sources.count) 个来源").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(profile.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle).help(profile.name)
            Text("按来源独立保留，旧段不混入当前统计与预测。\n统计时区：\(model.calendar.timeZone.identifier) · 缺记录不补零。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sources.enumerated()).reversed(), id: \.element.id) { entry in
                        SourceHistorySection(source: entry.element, number: entry.offset + 1, calendar: model.calendar,
                                             unit: model.trafficUnit, initiallyExpanded: entry.element.id == initial)
                        if entry.offset != 0 { Divider() }
                    }
                    if sources.isEmpty {
                        Text("暂无来源记录，首次成功读取后开始保留历史。")
                            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                }.padding(.horizontal, 4).padding(.trailing, 10)
            }
            HStack {
                Text("仅查看，不会请求订阅").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }.buttonStyle(WorkspaceButton()).keyboardShortcut(.cancelAction)
                    .focusable().focused($closeFocused)
                    .workspaceFocusCue(closeFocused)
                    .workspaceKeyboardActivation { dismiss() }
            }
        }.padding(20).frame(width: 480, height: 420).background(Magpie.surface)
            .onAppear { DispatchQueue.main.async { closeFocused = true } }
    }
}

private struct SourceHistorySection: View {
    let source: SourceRecord
    let number: Int
    let calendar: Calendar
    let unit: TrafficUnit
    @State private var expanded: Bool
    @State private var rawExpanded = false
    init(source: SourceRecord, number: Int, calendar: Calendar, unit: TrafficUnit, initiallyExpanded: Bool) {
        self.source = source; self.number = number; self.calendar = calendar; self.unit = unit
        _expanded = State(initialValue: initiallyExpanded)
    }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if expanded { records.padding(.top, 8) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(source.endedAt == nil ? "当前来源" : "旧来源") \(number)").fontWeight(.medium)
                    Spacer()
                    Text("\(source.ledger.samples.count) 次读数").foregroundStyle(.secondary)
                }
                Text("\(stamp(source.createdAt)) – \(source.endedAt.map(stamp) ?? "至今")")
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }
        }.font(.system(size: 11)).padding(.vertical, 12)
            .focusable().workspaceKeyboardActivation { expanded.toggle() }
    }
    private var records: some View {
        let report = SourceHistoryPresentation(source: source, calendar: calendar).report
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最后余额")
                Spacer()
                Text(source.ledger.samples.last?.subscription.remaining.map { unit.text($0) } ?? "未知").monospacedDigit()
            }
            if let report, report.bytes != nil {
                HStack {
                    Text("已记录用量").fontWeight(.medium)
                    Spacer()
                    Text(amount(report.bytes)).fontWeight(.medium).monospacedDigit()
                }
                HStack {
                    Text("日期 / 观测区间")
                    Spacer()
                    Text("记录用量")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach(report.daily.filter { $0.bytes != nil }) { day in
                    historyRow(dateOnly(day.date), amount(day.bytes))
                }
                ForEach(report.unallocated) { interval in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(stamp(interval.start)) –")
                            Text(stamp(interval.end))
                            Text("跨日未分配").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 10)
                        Text(amount(interval.bytes))
                    }.monospacedDigit()
                }
            } else {
                Text(source.ledger.samples.isEmpty ? "尚无成功读数。" : "仅有基线或不可比较读数，暂无可归属用量。")
                    .foregroundStyle(.secondary)
            }
            if let report, !report.excluded.isEmpty {
                Text("\(report.excluded.count) 个区间因重置、计数回退或规则变化未计入用量。")
                    .foregroundStyle(.secondary)
            }
            if !source.gaps.isEmpty {
                Text("\(source.gaps.count) 段监测中断已保留，未监测日期不补写每日用量。")
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup("原始读数 · \(source.ledger.samples.count) 次", isExpanded: $rawExpanded) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    HStack { Text("读取时间"); Spacer(); Text("剩余流量") }.foregroundStyle(.secondary)
                    ForEach(source.ledger.samples.reversed()) { sample in
                        historyRow(stamp(sample.date), sample.subscription.remaining.map { unit.text($0) } ?? "未知")
                    }
                }.padding(.top, 8)
            }.focusable().workspaceKeyboardActivation { rawExpanded.toggle() }
        }.font(.system(size: 11)).padding(.leading, 4)
    }
    private func historyRow(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(minLength: 10); Text(value) }.monospacedDigit()
    }
    private func amount(_ bytes: Double?) -> String { bytes.map { NativeFormat.amount($0, unit: unit) } ?? "—" }
    private func stamp(_ date: Date) -> String { format(date, "yyyy-MM-dd HH:mm") }
    private func dateOnly(_ date: Date) -> String { format(date, "yyyy-MM-dd") }
    private func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
