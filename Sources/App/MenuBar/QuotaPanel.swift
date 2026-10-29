import SwiftUI
import AppKit

enum PanelFormat {
    static func date(_ date: Date, time: Bool = false, zone: TimeZone = .current) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.timeZone = zone
        f.dateFormat = time ? "MM/dd HH:mm" : "yyyy.MM.dd"; return f.string(from: date)
    }
    static func syncTime(_ date: Date) -> String { Calendar.current.isDateInToday(date) ? NativeFormat.time(date) : PanelFormat.date(date, time: true) }
    static func countdown(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        if seconds <= 0 { return "已过期" }
        if seconds < 3600 { return "\(max(1, Int(ceil(seconds / 60))))分钟后" }
        if seconds < 86400 { return "\(Int(ceil(seconds / 3600)))小时后" }
        return "\(Int(ceil(seconds / 86400)))天后"
    }
}

struct QuotaPanel: View {
    @ObservedObject var workspace: AirportWorkspace
    let openMain: () -> Void
    let openSettings: () -> Void
    var contentHeightChanged: (CGFloat) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image("MenuBarIcon").renderingMode(.template).resizable().frame(width: 15, height: 15).accessibilityHidden(true)
                    Text("Airport Monitor").font(.system(size: 12, weight: workspace.menuPanelLayout == .magpie ? .semibold : .medium)).lineLimit(1).fixedSize()
                    if let model = workspace.menuModel { syncStatus(model) }
                }
                Spacer(minLength: 8)
                HStack(spacing: 2) {
                    if let model = workspace.menuModel {
                        Button { Task { await model.refresh() } } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 13))
                                .foregroundStyle(model.error == nil ? iconColor : Magpie.color(0x4B4B53, 0xC7C7D0))
                        }
                        .disabled(model.busy || !model.enabled || !model.hasURL || model.storageBlocked)
                        .help(model.error == nil ? "刷新" : "重试同步").accessibilityLabel(model.error == nil ? "刷新订阅" : "重试同步")
                    }
                    Button(action: openMain) { Image(systemName: "macwindow").font(.system(size: 13)).foregroundStyle(iconColor) }
                        .help("打开主窗口").accessibilityLabel("打开主窗口")
                    Button(action: openSettings) { Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(iconColor) }
                        .help("设置").accessibilityLabel("设置")
                }.buttonStyle(CompactIconButton())
            }.padding(.leading, 16).padding(.trailing, 10).frame(height: 44)
                .disabled(workspace.panelExplanationOpen).accessibilityHidden(workspace.panelExplanationOpen)
            if let profile = workspace.menuProfile, let model = workspace.menuModel {
                MenuAirportContent(workspace: workspace, model: model, profile: profile).id(profile.id)
            } else {
                VStack(spacing: 8) {
                    EmptyWorkspace(title: "添加第一个机场", detail: "添加订阅后，在这里查看套餐余量。")
                    Button("添加机场…", action: openMain).buttonStyle(CompactButton(prominent: true))
                }.padding(.bottom, 4).modifier(MeasurePanelHeight())
            }
            HStack {
                Spacer()
                Button { NSApplication.shared.terminate(nil) } label: {
                    Text("退出").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.8))
                        .padding(.horizontal, 9).frame(height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .help("退出 Airport Monitor").accessibilityLabel("退出 Airport Monitor")
            }.padding(.trailing, 10).frame(height: 28)
                .disabled(workspace.panelExplanationOpen).accessibilityHidden(workspace.panelExplanationOpen)
        }
        .frame(width: PanelPlacement.width).frame(maxHeight: .infinity, alignment: .top)
        .background(workspace.menuPanelLayout == .overview ? Magpie.surface : Magpie.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .tint(Magpie.accent)
        .onPreferenceChange(PanelNaturalHeight.self) { contentHeightChanged($0 + 44 + 28) }
        .onDisappear { workspace.panelExplanationOpen = false }
    }

    private var iconColor: Color { Magpie.color(0x6F6F79, 0xAAAAB4) }

    private func syncStatus(_ model: MonitorModel) -> some View {
        let failed = model.error != nil
        let text: String? = !model.enabled ? "已暂停" : model.busy ? "同步中" : failed ? shortError(model) : model.stale ? "读数过期" : nil
        let color: Color = !model.enabled ? iconColor : failed ? Magpie.color(0xEF4444, 0xF87171) : model.latest == nil ? iconColor : model.stale ? Magpie.warning : Magpie.color(0x16A34A, 0x4ADE80)
        let status = !model.enabled ? "同步已暂停" : model.busy ? "正在同步" : failed ? "同步失败：" + shortError(model) : model.latest == nil ? "等待首次同步" : model.stale ? "读数过期" : "同步成功"
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            if let text { Text(text).font(.system(size: 11)).foregroundStyle(failed ? Magpie.danger : iconColor).fixedSize() }
        }.padding(.horizontal, 2).frame(minWidth: 10, minHeight: 28)
            .accessibilityElement(children: .ignore)
            .help(status)
            .accessibilityLabel(status + (model.latest.map { "，当前读数时间" + PanelFormat.date($0.date, time: true) } ?? ""))
    }

    private func shortError(_ model: MonitorModel) -> String {
        if model.storageBlocked { return "读数受保护" }
        let error = (model.error ?? "").lowercased()
        if error.contains("超时") || error.contains("timed out") { return "连接超时" }
        if error.contains("网络") || error.contains("offline") || error.contains("连接") { return "连接失败" }
        return "同步失败"
    }
}

private struct PanelNaturalHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

private struct MeasurePanelHeight: ViewModifier {
    func body(content: Content) -> some View {
        content.background { GeometryReader { geometry in Color.clear.preference(key: PanelNaturalHeight.self, value: geometry.size.height) } }
    }
}

private struct MenuAirportContent: View {
    @ObservedObject var workspace: AirportWorkspace
    @ObservedObject var model: MonitorModel
    let profile: AirportProfile
    @State private var focusToken = 0

    var body: some View {
        MenuPlanCard(workspace: workspace, model: model, profile: profile, focusToken: focusToken) {
            workspace.panelExplanationOpen = true
        }
        .disabled(workspace.panelExplanationOpen)
        .accessibilityHidden(workspace.panelExplanationOpen)
        .overlay {
            if workspace.panelExplanationOpen {
                Color.black.opacity(0.22)
                VStack(alignment: .leading, spacing: 12) {
                    Text("余量如何计算").font(.system(size: 13, weight: .semibold))
                    Text("剩余 = 总额 − 上传 − 下载，最低为0。总额未知时不计算余量和比例。")
                    Text("颜色始终按剩余比例判断：超过50%为常规色，超过20%且不超过50%为警告色，20%及以下为红色。")
                    Text(model.trafficUnit.explanation).foregroundStyle(.secondary)
                    Button("返回", action: closeExplanation).buttonStyle(CompactButton()).keyboardShortcut(.cancelAction)
                }
                .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Magpie.surface, in: RoundedRectangle(cornerRadius: 10))
                .padding(12)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .modifier(MeasurePanelHeight())
        .onExitCommand { if workspace.panelExplanationOpen { closeExplanation() } }
    }

    private func closeExplanation() {
        workspace.panelExplanationOpen = false
        focusToken += 1
    }
}

private struct MenuPlanCard: View {
    @ObservedObject var workspace: AirportWorkspace
    @ObservedObject var model: MonitorModel
    let profile: AirportProfile
    let focusToken: Int
    let showHelp: () -> Void
    @State private var showUsed = false
    @State private var pickerHovered = false
    @FocusState private var helpFocused: Bool

    private var info: Subscription? { model.latest?.subscription }
    private var presentation: MenuQuotaPresentation { MenuQuotaPresentation(subscription: info) }
    private var known: Bool { info.map { $0.total > 0 } ?? false }
    private var mode: String { showUsed ? "已用" : "剩余" }
    private var fraction: Double { guard let info, known else { return 0 }; return showUsed ? info.fraction : 1 - info.fraction }
    private var ratio: String { NativeFormat.percentage(fraction) }
    private var muted: Color { Magpie.color(0x6F6F79, 0xAAAAB4) }

    var body: some View {
        Group {
            if workspace.menuPanelLayout == .overview { overview }
            else { magpie }
        }.onChange(of: focusToken) { _, _ in helpFocused = true }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            airportPicker
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    quotaLabel
                    Spacer(minLength: 8)
                    balance
                }.frame(height: 32)
                if known {
                    Button { showUsed.toggle() } label: { quotaBar.padding(.vertical, 7).contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(mode + " " + ratio + "，切换比例")
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("总额 " + (known ? value(info!.total) + " " + model.trafficUnit.label : info == nil ? "—" : "未知"))
                    Spacer(minLength: 8)
                    if known {
                        Button { showUsed.toggle() } label: {
                            HStack(spacing: 4) { Text(mode + " " + ratio); Image(systemName: "chevron.down").font(.system(size: 7)) }
                        }.buttonStyle(.plain).accessibilityLabel(mode + " " + ratio + "，切换比例")
                    } else { Text("比例未知") }
                }.font(.system(size: 11)).foregroundStyle(muted).frame(height: 20)
            }.padding(.top, 14).padding(.bottom, 10)
            HStack(alignment: .top, spacing: 12) {
                overviewMetric("已用", bytes: info?.used, size: 15, weight: .semibold)
                overviewMetric("上传", icon: "arrow.up", bytes: info?.upload)
                overviewMetric("下载", icon: "arrow.down", bytes: info?.download)
            }.padding(10).background(Magpie.secondary, in: RoundedRectangle(cornerRadius: 6))
            ResetScheduleRow(model: model).frame(height: 28).padding(.top, 8)
            expiryRow.frame(height: 31)
        }.padding(.horizontal, 16)
    }

    private var magpie: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    MenuQuotaMark().stroke(muted, style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
                        .frame(width: 13, height: 13).offset(y: 0.5).accessibilityHidden(true)
                    Text("订阅额度").font(.system(size: 11, weight: .semibold))
                }
                Spacer(minLength: 12)
                Text("流量").font(.system(size: 11))
                Button { showUsed.toggle() } label: {
                    HStack(spacing: 3) {
                        Text(known ? mode : info == nil ? "未知" : "—")
                        if known { Image(systemName: "arrow.left.arrow.right").font(.system(size: 7, weight: .semibold)).accessibilityHidden(true) }
                    }.font(.system(size: 10)).padding(.horizontal, 4).padding(.vertical, 2).background(Magpie.line, in: Capsule())
                        .frame(width: 40, height: 28)
                }.buttonStyle(.plain).disabled(!known)
                    .accessibilityLabel(known ? "额度显示：" + mode + "，切换比例" : "额度未知，不能切换比例")
            }.foregroundStyle(muted).frame(height: 28).padding(.horizontal, 4).padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 0) {
                airportPicker.padding(.horizontal, -12).padding(.bottom, 12)
                VStack(alignment: .leading, spacing: 0) {
                    quotaLabel.frame(height: 24)
                    HStack(alignment: .firstTextBaseline) {
                        balance
                        Spacer(minLength: 12)
                        if known {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(mode).font(.system(size: 11)).foregroundStyle(muted)
                                Text(ratio).font(.system(size: 13, weight: .medium))
                            }
                        }
                    }.frame(height: 32)
                    if known {
                        quotaBar.padding(.top, 8).padding(.bottom, 11)
                            .accessibilityElement(children: .ignore).accessibilityLabel(mode + "额度").accessibilityValue(ratio)
                    } else {
                        Text(info == nil ? "等待首次同步" : "缺少总额信息，无法计算余量")
                            .font(.system(size: 11)).foregroundStyle(muted).frame(height: 18).padding(.top, 8).padding(.bottom, 4)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        captionMetric("已用", bytes: info?.used)
                        Spacer(minLength: 12)
                        captionMetric("总额", bytes: known ? info?.total : nil)
                    }.frame(height: 20)
                }
                HStack(alignment: .top) {
                    transfer("上传", icon: "arrow.up", bytes: info?.upload, alignment: .leading)
                    Spacer(minLength: 20)
                    transfer("下载", icon: "arrow.down", bytes: info?.download, alignment: .trailing)
                }.padding(.top, 10)
                ResetScheduleRow(model: model).frame(height: 24).padding(.top, 10)
                expiryRow.frame(height: 28)
            }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 8)
                .background(Magpie.surface, in: RoundedRectangle(cornerRadius: 10))
        }.padding(.horizontal, 12)
    }

    private var airportPicker: some View {
        Menu {
            ForEach(workspace.activeProfiles) { airport in
                Button { workspace.menuAirport = airport.id } label: {
                    Label(airport.name, systemImage: airport.id == workspace.menuAirport ? "checkmark" : "cloud")
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "cloud").font(.system(size: 13)).frame(width: 14).foregroundStyle(muted).accessibilityHidden(true)
                Text(profile.name).font(.system(size: workspace.menuPanelLayout == .magpie ? 13 : 12, weight: workspace.menuPanelLayout == .magpie ? .semibold : .medium))
                    .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(muted).accessibilityHidden(true)
            }.padding(.horizontal, 9).frame(height: 32).contentShape(Rectangle())
                .background(pickerHovered ? Magpie.pill : Magpie.secondary, in: RoundedRectangle(cornerRadius: 6))
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).tint(.primary)
            .frame(maxWidth: .infinity).onHover { pickerHovered = $0 }
            .help(profile.name).accessibilityLabel("切换菜单栏机场，当前为" + profile.name)
    }

    private var quotaLabel: some View {
        HStack(spacing: 2) {
            Text("剩余流量").font(.system(size: 11)).foregroundStyle(muted)
            Button(action: showHelp) { Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(muted).frame(width: 24, height: 24) }
                .buttonStyle(.plain).focused($helpFocused).help("余量计算说明").accessibilityLabel("余量计算说明")
        }
    }

    @ViewBuilder private var balance: some View {
        if let remaining = info?.remaining, known {
            reading(remaining, size: 24, unitSize: 11, weight: .semibold, color: presentation.risk.color, decimals: 1)
                .accessibilityLabel("剩余流量 " + value(remaining, decimals: 1) + " " + model.trafficUnit.label)
        } else { Text("余量未知").font(.system(size: 18, weight: .semibold)).lineLimit(1) }
    }

    private var quotaBar: some View {
        GeometryReader { geometry in
            Capsule().fill(Magpie.pill)
                .overlay(alignment: .leading) {
                    Capsule().fill(presentation.barColor).frame(width: geometry.size.width * max(0, min(1, fraction)))
                }
        }.frame(height: 5)
    }

    private var expiryRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("到期时间").font(.system(size: 11)).foregroundStyle(muted)
            Spacer(minLength: 12)
            Text(info?.expiry.map { PanelFormat.date($0).replacingOccurrences(of: ".", with: "/") } ?? (info == nil ? "待同步" : "未提供"))
                .font(.system(size: workspace.menuPanelLayout == .magpie ? 12 : 11, weight: .medium))
                .foregroundStyle(model.expired ? Magpie.danger : Color.primary).monospacedDigit().lineLimit(1)
        }
    }

    private func overviewMetric(_ title: String, icon: String? = nil, bytes: UInt64?, size: CGFloat = 13, weight: Font.Weight = .medium) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            metricLabel(title, icon: icon).frame(height: 15)
            reading(bytes, size: size, weight: weight).frame(height: 19)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func transfer(_ title: String, icon: String, bytes: UInt64?, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            metricLabel(title, icon: icon).frame(height: 16)
            reading(bytes, size: 13, weight: .medium).frame(height: 22)
        }
    }

    private func captionMetric(_ title: String, bytes: UInt64?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(muted)
            reading(bytes, size: 13, weight: .semibold)
        }
    }

    private func metricLabel(_ title: String, icon: String?) -> some View {
        HStack(spacing: 3) {
            Text(title)
            if let icon { Image(systemName: icon).font(.system(size: 9)).accessibilityHidden(true) }
        }.font(.system(size: 11)).foregroundStyle(muted)
    }

    private func reading(_ bytes: UInt64?, size: CGFloat, unitSize: CGFloat = 10, weight: Font.Weight, color: Color = .primary, decimals: Int = 2) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(bytes.map { value($0, decimals: decimals) } ?? "—")
                .font(.system(size: size, weight: weight)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.65)
            if bytes != nil { Text(model.trafficUnit.label).font(.system(size: unitSize)).foregroundStyle(muted) }
        }.monospacedDigit()
    }

    private func value(_ bytes: UInt64, decimals: Int = 2) -> String {
        (Double(bytes) / model.trafficUnit.divisor).formatted(.number.precision(.fractionLength(0...decimals)).locale(Locale(identifier: "en_US")))
    }
}

private struct MenuQuotaMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (x, top) in [(5.0, 12.0), (12.0, 3.0), (19.0, 8.0)] {
            path.move(to: CGPoint(x: rect.minX + rect.width * x / 24, y: rect.minY + rect.height * 21 / 24))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * x / 24, y: rect.minY + rect.height * top / 24))
        }
        return path
    }
}

struct ResetScheduleRow: View {
    @ObservedObject var model: MonitorModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let reset = ResetPresentation(rule: model.resetRule, at: model.isDemo ? model.referenceDate : context.date, displayTimeZone: .autoupdatingCurrent)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("预计重置").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(reset.value).fontWeight(.medium).foregroundStyle(reset.next == nil ? .secondary : .primary)
                    .monospacedDigit().lineLimit(1)
            }.font(.system(size: 11)).help(reset.detail)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("预计重置，\(reset.value)。\(reset.detail)")
        }
    }
}

struct PlanFacts: View {
    @ObservedObject var model: MonitorModel
    let plan: String
    var body: some View {
        if let info = model.latest?.subscription {
            VStack(spacing: 7) {
                if !plan.isEmpty { fact("套餐名称", plan) }
                fact("累计已用", model.trafficUnit.text(info.used))
                fact("上传", model.trafficUnit.text(info.upload))
                fact("下载", model.trafficUnit.text(info.download))
            }.padding(.top, 4)
        }
    }
    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).monospacedDigit()
        }.font(.system(size: 11))
    }
}

struct SyncNotice: View {
    @ObservedObject var model: MonitorModel
    let name: String
    var body: some View {
        if let error = model.error {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) { Text(model.storageBlocked ? "历史受保护" : "同步失败").foregroundStyle(Magpie.warning); if let date = model.latest?.date { Text("沿用 \(PanelFormat.syncTime(date)) 的读数").foregroundStyle(.secondary) } }
                    Text(error).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }.font(.system(size: 11))
                Spacer(minLength: 0)
                if !model.storageBlocked { Button { Task { await model.refresh() } } label: { Text(model.busy ? "重试中…" : "重试").foregroundStyle(Magpie.warning) }.buttonStyle(CompactButton()).disabled(model.busy || !model.enabled || model.isDemo).accessibilityLabel("重试\(name)") }
            }.padding(9).background(BasicQuotaPresentation(model: model).risk == .danger ? Magpie.secondary : Magpie.warningSurface, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
