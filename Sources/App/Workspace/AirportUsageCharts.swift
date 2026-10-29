import SwiftUI
import Charts
#if SWIFT_PACKAGE
import TrafficCore
#endif

struct AirportUsageCharts: View {
    @ObservedObject var model: MonitorModel
    let refreshDate: Date
    let airportName: String
    let editResetRule: () -> Void
    let resetActionFocusToken: UUID
    @State private var range = UsageStatisticsRange.week
    @State private var selectedDate: Date?
    @FocusState private var chartFocused: Bool
    @FocusState private var detailsCloseFocused: Bool
    @FocusState private var detailsButtonFocused: Bool
    @State private var showDetails = false
    private var period: DateInterval {
        range.period(at: model.referenceDate, calendar: model.calendar, rule: model.resetRule)
            ?? DateInterval(start: model.referenceDate, duration: 0)
    }
    private var cycleAvailable: Bool { UsageStatisticsRange.cycle.period(at: model.referenceDate, calendar: model.calendar, rule: model.resetRule) != nil }
    var body: some View {
        let report = model.statistics(in: period)
        HStack(alignment: .top, spacing: 14) {
            statistics(report).frame(maxWidth: .infinity)
            Rectangle().fill(Magpie.line).frame(width: 1)
            AirportForecastChart(model: model, refreshDate: refreshDate, airportName: airportName,
                                 editResetRule: editResetRule, resetActionFocusToken: resetActionFocusToken)
                .frame(maxWidth: .infinity)
        }.fixedSize(horizontal: false, vertical: true)
            .environment(\.calendar, model.calendar).environment(\.timeZone, model.calendar.timeZone)
    }
    private func statistics(_ report: UsageReport) -> some View {
        let selected = selectedDate.flatMap { date in report.daily.first { model.calendar.isDate($0.date, inSameDayAs: date) } }
        let hasDailyRecords = report.daily.contains { $0.bytes != nil }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("用量统计").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
                WorkspaceSegments(title: "统计范围", selection: $range, options: [("7天", .week), ("30天", .month), ("本周期", .cycle)],
                                  disabledValues: cycleAvailable ? [] : [.cycle])
                    .help(cycleAvailable ? "按统计时区筛选；本周期从最近重置开始" : "设置有效重置规则后，可查看本周期")
                    .onChange(of: range) { _, _ in selectedDate = nil }
                    .onChange(of: cycleAvailable) { _, available in if !available && range == .cycle { range = .week; selectedDate = nil } }
            }.frame(height: 28)
            HStack {
                Text("\(dateText(period.start))–\(dateText(range == .cycle ? period.end : period.end.addingTimeInterval(-1)))").monospacedDigit()
                Spacer()
                Text(model.trafficUnit.label)
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                WorkspaceMetric(title: report.unallocated.isEmpty ? "期间已记录" : "期间已记录（含跨日）",
                                value: amount(report.bytes))
                    .help(report.unallocated.isEmpty ? "期间内完整记录的用量" : "期间已记录包含跨日未分配用量")
                Spacer(minLength: 8)
                WorkspaceMetric(title: "今天已记录", value: amount(report.daily.last?.bytes))
            }.frame(height: 44, alignment: .top)
            ZStack(alignment: .leading) {
                if hasDailyRecords {
                    Chart {
                        if let selected, let end = model.calendar.date(byAdding: .day, value: 1, to: selected.date) {
                            RectangleMark(xStart: .value("所选日期", selected.date), xEnd: .value("次日", end),
                                          yStart: .value("底部", 0),
                                          yEnd: .value("顶部", max(1, (report.daily.compactMap(\.bytes).max() ?? 0) / model.trafficUnit.divisor * 1.15)))
                                .foregroundStyle(Magpie.accent.opacity(0.10)).accessibilityHidden(true)
                        }
                        ForEach(report.daily) { day in
                            if let bytes = day.bytes {
                                BarMark(x: .value("日期", day.date, unit: .day), y: .value("已记录用量", bytes / model.trafficUnit.divisor))
                                    .foregroundStyle(Magpie.accent.opacity(selected?.id == day.id ? 1 : 0.62)).cornerRadius(2)
                                if bytes == 0 {
                                    PointMark(x: .value("日期", day.date, unit: .day), y: .value("已记录用量", 0))
                                        .symbolSize(10).foregroundStyle(Magpie.accent)
                                }
                            }
                        }
                        if let selected {
                            RuleMark(x: .value("所选日期", selected.date, unit: .day))
                                .foregroundStyle(Color.secondary.opacity(0.35))
                        }
                    }
                    .chartXScale(domain: model.calendar.startOfDay(for: period.start)...max(period.end, period.start.addingTimeInterval(1)))
                    .chartYScale(domain: 0...max(1, (report.daily.compactMap(\.bytes).max() ?? 0) / model.trafficUnit.divisor * 1.15))
                    .chartXAxis {
                        AxisMarks(values: statisticsTicks) { value in
                            AxisValueLabel(centered: false,
                                           anchor: value.index == 0 ? .topLeading : value.index == value.count - 1 ? .topTrailing : .top,
                                           collisionResolution: .disabled) {
                                if let date = value.as(Date.self) {
                                    Text(dateText(date)).font(.system(size: 10)).monospacedDigit()
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                            AxisGridLine().foregroundStyle(Color.secondary.opacity(0.18))
                            AxisValueLabel().font(.system(size: 10).monospacedDigit())
                        }
                    }
                    .chartXSelection(value: $selectedDate)
                } else {
                    dailyEmptyState(report)
                }
            }
            .frame(height: 96)
            .accessibilityElement(children: .contain)
            .focusable().focused($chartFocused)
            .workspaceFocusCue(chartFocused)
            .onMoveCommand { direction in
                guard direction == .left || direction == .right else { return }
                moveSelection(direction == .left ? -1 : 1, in: report)
            }
            .onKeyPress(.home) { selectedDate = report.daily.first?.date; return .handled }
            .onKeyPress(.end) { selectedDate = report.daily.last?.date; return .handled }
            .onKeyPress(.escape) { guard selectedDate != nil else { return .ignored }; selectedDate = nil; return .handled }
            .accessibilityLabel("每日已记录用量，单位\(model.trafficUnit.label)；方向键选择日期，Esc清除")
            .accessibilityValue(selected != nil || hasDailyRecords ? selectionSummary(selected) : emptyDailySummary(report))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: moveSelection(1, in: report)
                case .decrement: moveSelection(-1, in: report)
                @unknown default: break
                }
            }
            HStack(alignment: .top, spacing: 4) {
                if let selected {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(dateText(selected.date)) · \(selected.bytes == nil ? "无记录" : amount(selected.bytes))").fontWeight(.medium).monospacedDigit()
                        Text(selected.bytes == nil ? (selected.hasUnallocated ? "跨日区间未分配到当天" : "缺少可归属记录，不代表零用量") : selected.bytes == 0 ? "已记录为零，区别于缺记录" : "已记录部分，不代表完整自然日")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button { selectedDate = nil; chartFocused = true } label: {
                        Image(systemName: "xmark").font(.system(size: 10)).frame(width: 22, height: 22).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("清除日期选择").help("清除选择 · Esc")
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(hasDailyRecords ? "已记录用量 · \(model.trafficUnit.label)" : "缺记录不代表零用量")
                        if hasDailyRecords { Text("空白为缺记录，圆点为真实零增长").foregroundStyle(.secondary) }
                    }
                }
            }.font(.system(size: 11)).frame(height: 32, alignment: .top)
            Button { showDetails.toggle() } label: {
                Text(report.unallocatedBytes.map { "跨日未分配 \(amount($0)) · 统计说明" } ?? "统计说明与区间")
                    .font(.system(size: 11)).lineLimit(1)
            }.buttonStyle(.plain).foregroundStyle(.secondary).focusable().focused($detailsButtonFocused)
                .workspaceFocusCue(detailsButtonFocused)
                .workspaceKeyboardActivation { showDetails.toggle() }
                .popover(isPresented: $showDetails) { statisticsDetails(report) }
                .onChange(of: showDetails) { _, visible in if !visible { detailsButtonFocused = true } }
        }
    }
    private func dailyEmptyState(_ report: UsageReport) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(report.unallocated.isEmpty ? "暂无每日明细" : "已有区间用量，无法按天分配")
                .font(.system(size: 12, weight: .medium))
            Text(emptyDailySummary(report))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
    private func emptyDailySummary(_ report: UsageReport) -> String {
        if !report.unallocated.isEmpty {
            return "跨日区间已计入期间汇总，无法确定每日分布。"
        }
        if !report.partial.isEmpty || !report.excluded.isEmpty {
            return "范围内没有可归属的每日记录。跨界或不可比较的区间未计入，详见统计说明。"
        }
        return "所选范围尚未形成可归属的每日记录。成功采样后逐步积累，缺失日期不补零。"
    }
    private func statisticsDetails(_ report: UsageReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("统计口径").font(.system(size: 12, weight: .medium))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("时区：\(model.calendar.timeZone.identifier)。统计服务商计入套餐的消耗。跨日差额不摊到某一天，只有完整覆盖区间的筛选才累计。缺失不补零。")
                    if !report.unallocated.isEmpty {
                        Text("跨日未分配 · \(report.unallocated.count) 个区间").fontWeight(.medium)
                        ForEach(report.unallocated) { item in
                            Text("\(dateText(item.start))–\(dateText(item.end))  \(amount(item.bytes))")
                                .accessibilityLabel("\(accessibleDate(item.start, includesTime: true))至\(accessibleDate(item.end, includesTime: true))，未分配用量\(amount(item.bytes))")
                        }
                    }
                    if !report.excluded.isEmpty { Text("\(report.excluded.count) 个不可比较区间：重置、计数回退或口径变化不计入用量。") }
                    if !report.partial.isEmpty { Text("\(report.partial.count) 个区间仅部分落入范围，未按比例计入。") }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 10)
            }.frame(maxHeight: 300)
            Button("关闭") { showDetails = false }
                .keyboardShortcut(.cancelAction).focusable().focused($detailsCloseFocused)
                .workspaceFocusCue(detailsCloseFocused)
                .workspaceKeyboardActivation { showDetails = false }
        }.font(.system(size: 11)).padding(16).frame(width: 320)
            .onAppear { detailsCloseFocused = true }
            .onExitCommand { showDetails = false }
    }
    private func amount(_ bytes: Double?) -> String { bytes.map { NativeFormat.amount($0, unit: model.trafficUnit) } ?? "—" }
    private func moveSelection(_ offset: Int, in report: UsageReport) {
        guard !report.daily.isEmpty else { return }
        let index = selectedDate.flatMap { date in
            report.daily.firstIndex { model.calendar.isDate($0.date, inSameDayAs: date) }
        } ?? (offset < 0 ? report.daily.count : -1)
        selectedDate = report.daily[min(report.daily.count - 1, max(0, index + offset))].date
    }
    private func selectionSummary(_ selected: DailyUsageObservation?) -> String {
        guard let selected else { return "未选择日期。空白为缺少记录，圆点为已观测的零增长。" }
        let date = accessibleDate(selected.date)
        guard let bytes = selected.bytes else {
            return "\(date)，缺少每日记录。\(selected.hasUnallocated ? "跨日区间未分配到当天。" : "当天没有可归属记录。")"
        }
        return "\(date)，已记录\(amount(bytes))。\(bytes == 0 ? "真实零增长。" : "")已记录部分，不代表完整自然日。"
    }
    private func accessibleDate(_ date: Date, includesTime: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.calendar = model.calendar; formatter.timeZone = model.calendar.timeZone
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = includesTime ? "yyyy年M月d日 HH:mm" : "yyyy年M月d日"
        return formatter.string(from: date)
    }
    private var statisticsTicks: [Date] {
        // Four complete dates fit the narrow chart. Construct them with the
        // persisted statistics calendar rather than dividing elapsed DST hours.
        let start = model.calendar.startOfDay(for: period.start)
        let end = range == .cycle ? period.end : period.end.addingTimeInterval(-1)
        let count = max(0, model.calendar.dateComponents([.day], from: start, to: model.calendar.startOfDay(for: end)).day ?? 0)
        return Array(Set([0, count / 3, count * 2 / 3, count])).sorted().compactMap { model.calendar.date(byAdding: .day, value: $0, to: start) }
    }
    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.timeZone = model.calendar.timeZone; formatter.dateFormat = "MM/dd"
        return formatter.string(from: date)
    }
}

private struct AirportForecastChart: View {
    @ObservedObject var model: MonitorModel
    let refreshDate: Date
    let airportName: String
    let editResetRule: () -> Void
    let resetActionFocusToken: UUID
    @State private var showBasis = false
    @FocusState private var basisButtonFocused: Bool
    @FocusState private var basisCloseFocused: Bool
    @FocusState private var resetActionFocused: Bool
    var body: some View {
        let result = model.samplingForecastResult
        let historical = model.samplingForecastIsHistorical
        let trend = model.balanceTrend
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("用量预测").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
                Text(historical ? "历史估计" : result.estimate != nil ? "估计" : "暂不可用").font(.system(size: 10)).foregroundStyle(.secondary)
            }.frame(height: 28)
            HStack {
                Text(result.estimate?.boundary.map { "预计至 \(dateText($0))" } ?? "等待有效预测区间").monospacedDigit()
                Spacer()
                Text(model.trafficUnit.label)
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                WorkspaceMetric(title: result.estimate?.boundaryKind == .expiry ? "到期预计剩余" : "重置预计剩余",
                                value: result.estimate?.remainingAtBoundary.map { "≈ " + NativeFormat.amount($0, unit: model.trafficUnit) } ?? "—")
                WorkspaceMetric(title: "观测日均", value: result.estimate.map { NativeFormat.amount($0.dailyBytes, unit: model.trafficUnit) } ?? "—")
            }.frame(height: 44, alignment: .top)
            if let estimate = result.estimate, let latest = model.latest, let remaining = latest.subscription.remaining,
               let boundary = estimate.boundary, boundary > latest.date {
                let endpoint = min(boundary, estimate.exhaustion ?? boundary)
                let projectedRemaining = max(0, Double(remaining) - estimate.dailyBytes * endpoint.timeIntervalSince(latest.date) / 86400)
                let chartStart = trend.recorded.first?.first?.date ?? latest.date
                let chartMiddle = chartStart.addingTimeInterval(boundary.timeIntervalSince(chartStart) / 2)
                Chart {
                    ForEach(Array(trend.recorded.enumerated()), id: \.offset) { segment in
                        ForEach(Array(segment.element.enumerated()), id: \.offset) { item in
                            LineMark(x: .value("时间", item.element.date), y: .value("余量", item.element.bytes / model.trafficUnit.divisor),
                                     series: .value("连续区间", "recorded-\(segment.offset)"))
                                .foregroundStyle(Magpie.accent.opacity(0.55)).lineStyle(StrokeStyle(lineWidth: 1.5))
                            if segment.element.count == 1 {
                                PointMark(x: .value("时间", item.element.date), y: .value("余量", item.element.bytes / model.trafficUnit.divisor))
                                    .foregroundStyle(Magpie.accent.opacity(0.55)).symbolSize(10)
                            }
                        }
                    }
                    LineMark(x: .value("时间", latest.date), y: .value("余量", Double(remaining) / model.trafficUnit.divisor), series: .value("连续区间", "forecast"))
                        .foregroundStyle(Magpie.accent).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    LineMark(x: .value("时间", endpoint), y: .value("余量", projectedRemaining / model.trafficUnit.divisor), series: .value("连续区间", "forecast"))
                        .foregroundStyle(Magpie.accent).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    PointMark(x: .value("时间", latest.date), y: .value("余量", Double(remaining) / model.trafficUnit.divisor))
                        .foregroundStyle(Magpie.accent).symbolSize(20)
                }.chartXScale(domain: chartStart...boundary)
                    .chartYScale(domain: 0...max(1, max(Double(remaining), trend.upperBytes) / model.trafficUnit.divisor * 1.1))
                    .chartXAxis {
                        AxisMarks(values: [chartStart, chartMiddle, boundary]) { value in
                            // Keep edge labels inside the plot instead of allowing
                            // automatic collision handling to drop the reset date.
                            AxisValueLabel(centered: false,
                                           anchor: value.index == 0 ? .topLeading : value.index == 2 ? .topTrailing : .top,
                                           collisionResolution: .disabled) {
                                if let date = value.as(Date.self) {
                                    Text(dateText(date)).font(.system(size: 10)).monospacedDigit()
                                }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                            AxisGridLine().foregroundStyle(Color.secondary.opacity(0.18))
                            AxisValueLabel().font(.system(size: 10).monospacedDigit())
                        }
                    }
                    .frame(height: 96).opacity(!historical ? 1 : 0.6)
                    .accessibilityLabel(!historical ? "当前用量预测" : "历史用量预测")
                    .accessibilityValue(forecastSummary(result, historical: historical))
            } else {
                forecastUnavailable(result, detail: snapshotDetail(result))
            }
            VStack(alignment: .leading, spacing: 3) {
                if historical {
                    Text("历史估计")
                } else if result.estimate != nil {
                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            Capsule().fill(Magpie.accent.opacity(0.55)).frame(width: 14, height: 2)
                            Text("已记录余量")
                        }
                        HStack(spacing: 4) {
                            Path { path in path.move(to: .zero); path.addLine(to: CGPoint(x: 16, y: 0)) }
                                .stroke(Magpie.accent, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])).frame(width: 16, height: 2)
                            Text("未来估计")
                        }
                    }
                }
                if result.estimate != nil {
                    Text("基于 \(PanelFormat.syncTime(result.generatedAt)) 读数 · 仅供参考").foregroundStyle(.secondary)
                }
            }.font(.system(size: 11)).frame(height: 32, alignment: .top)
            Button("预测依据") { showBasis = true }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                .focusable().focused($basisButtonFocused)
                .workspaceFocusCue(basisButtonFocused)
                .workspaceKeyboardActivation { showBasis = true }
                .popover(isPresented: $showBasis) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("预测依据").font(.system(size: 12, weight: .medium))
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(forecastSummary(result, historical: historical))
                                Text(snapshotDetail(result))
                                Text("每次成功读取后按累计增长与实际经过时间更新，平时保留结果；不分摊每日用量。跨重置、计数回退、额度或来源／规则变化后重新积累。")
                                Text("同一订阅至少间隔72小时读取；至少4次读数，跨度至少3个采样间隔，相邻间断不超过2个采样间隔。消耗速度变化会影响结果，预测不代表当前余额；通知仍采用原有严格资格。")
                                    .foregroundStyle(.secondary)
                            }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
                        }.frame(maxHeight: 280)
                        Button("关闭") { showBasis = false }.keyboardShortcut(.cancelAction)
                            .focusable().focused($basisCloseFocused)
                            .workspaceFocusCue(basisCloseFocused)
                            .workspaceKeyboardActivation { showBasis = false }
                    }.padding(16).frame(width: 320)
                        .onAppear { basisCloseFocused = true }
                }
                .onChange(of: showBasis) { _, visible in if !visible { basisButtonFocused = true } }
        }
        .onChange(of: resetActionFocusToken) { _, _ in
            if model.resetRule.kind == .none { resetActionFocused = true }
        }
    }
    private func snapshotDetail(_ result: ForecastResult) -> String {
        switch result.diagnostic {
        case .missingReset: return "设置有效重置规则后才能预测重置时余量。"
        case .expiryBeforeReset: return "到期不晚于重置，不作可用至重置的预测。"
        case .zeroGrowth: return "尚未观测到消耗增长，不据此承诺未来够用。"
        case .unknownRemaining: return "服务端总量或余量未知，无法预测。"
        case .awaitingReset: return "等待成功读取新周期数据。"
        case .expired: return "该读数的套餐已到期。"
        case .noData: return "首次成功同步只建立基线，之后积累可比较读数。"
        default: return "依据上次成功采样的平均消耗速度推算；实际消耗变化会影响结果。"
        }
    }
    private func forecastUnavailable(_ result: ForecastResult, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.resetRule.kind == .none {
                Text("暂不估计").fontWeight(.medium)
                Text("预测需要设置重置规则并积累足够读数。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("设置重置规则", action: editResetRule)
                    .buttonStyle(.plain).foregroundStyle(Magpie.accent)
                    .focusable().focused($resetActionFocused).workspaceFocusCue(resetActionFocused)
                    .workspaceKeyboardActivation(editResetRule)
                    .accessibilityLabel("设置\(airportName)的重置规则")
            } else if result.diagnostic == .insufficientHistory {
                Text("历史不足，暂不估计").fontWeight(.medium)
                HStack(spacing: 8) {
                    readiness("观察跨度", "\(Int(result.observedSeconds / 86400)) / \(SubscriptionRefreshPolicy.normalized(model.intervalMinutes) * 3 / 1440) 天")
                    readiness("有效读数", "\(result.sampleCount) / 4 次")
                    readiness("覆盖日期", "\(result.eligibleDays) / 3 天")
                }
                Text("成功采样后更新，至少需要4次可比较读数。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text("暂不估计").fontWeight(.medium)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.font(.system(size: 11)).frame(maxWidth: .infinity, minHeight: 96, maxHeight: 96, alignment: .leading)
    }
    private func readiness(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).monospacedDigit()
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.timeZone = model.calendar.timeZone; formatter.dateFormat = "MM/dd"
        return formatter.string(from: date)
    }
    private func forecastSummary(_ result: ForecastResult, historical: Bool) -> String {
        guard let estimate = result.estimate else { return "暂不估计" }
        let formatter = DateFormatter()
        formatter.calendar = model.calendar; formatter.timeZone = model.calendar.timeZone
        formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = "yyyy年M月d日 HH:mm"
        var parts = [historical ? "历史估计，不作当前风险判断" : "采样时估计，仅供参考",
                     "基于\(formatter.string(from: result.generatedAt))读数，统计时区\(model.calendar.timeZone.identifier)"]
        if let boundary = estimate.boundary {
            parts.append("\(formatter.string(from: boundary))\(estimate.boundaryKind == .expiry ? "到期" : "重置")")
        }
        if let remaining = estimate.remainingAtBoundary {
            parts.append("届时预计剩余\(NativeFormat.amount(remaining, unit: model.trafficUnit))")
        }
        if estimate.runsOutBeforeBoundary, let exhaustion = estimate.exhaustion {
            parts.append("预计提前于\(formatter.string(from: exhaustion))用尽")
        }
        parts.append("观测日均\(NativeFormat.amount(estimate.dailyBytes, unit: model.trafficUnit))，\(result.sampleCount)次读数")
        return parts.joined(separator: "。")
    }
}
