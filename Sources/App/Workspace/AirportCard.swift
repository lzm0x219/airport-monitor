import SwiftUI

struct AirportCard: View {
    @ObservedObject var workspace: AirportWorkspace
    @ObservedObject var model: MonitorModel
    let profile: AirportProfile
    let edit: () -> Void
    let announce: (String) -> Void
    let beginOperation: () -> Void
    let onArchived: () -> Void
    @Binding var editorFocusReturnID: UUID?
    @State private var confirmArchive = false
    @State private var statusExpanded = false
    @State private var historyExpanded = false
    @State private var editingFromForecast = false
    @State private var resetActionFocusToken = UUID()
    @FocusState private var statusFocused: Bool
    @FocusState private var statusCloseFocused: Bool
    @FocusState private var syncFocused: Bool
    @FocusState private var configurationFocused: Bool
    @FocusState private var moreFocused: Bool
    @FocusState private var historyFocused: Bool
    @State private var historyFromLink = false
    @State private var configurationFocusGeneration = UUID()
    private var presentation: WorkspacePresentation { WorkspacePresentation(model: model) }
    private var statusColor: Color {
        if model.storageBlocked { return Magpie.danger }
        if model.busy || !profile.enabled { return .secondary }
        if model.error != nil { return Magpie.danger }
        if model.syncPending || model.linkVerificationPending || model.stale || model.latest == nil { return .secondary }
        return Color.green
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let refreshDate = model.referenceDate
            Surface(verticalPadding: 12, horizontalPadding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    topLine
                    quotaSummary
                    Rectangle().fill(Magpie.line).frame(height: 1)
                    // The explicit tick invalidates both chart subviews even when no
                    // network result changes the observable model. Identity stays stable.
                    AirportUsageCharts(model: model, refreshDate: refreshDate, airportName: profile.name,
                        editResetRule: {
                            clearConfigurationFocus(); editingFromForecast = true; edit()
                        }, resetActionFocusToken: resetActionFocusToken)
                    if workspace.sourceHistory(for: profile).count > 1 {
                        Button("查看旧来源历史") { historyFromLink = true; historyExpanded = true }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).focusable().focused($historyFocused)
                            .workspaceFocusCue(historyFocused)
                            .workspaceKeyboardActivation { historyFromLink = true; historyExpanded = true }
                    }
                }
            }
        }.alert("移除\(profile.name)？", isPresented: $confirmArchive) {
            Button("取消", role: .cancel) {}
            Button("移除并保留历史") {
                if workspace.archive(profile, archived: true) {
                    announce("已移除\(profile.name)，可从已移除机场恢复"); onArchived()
                }
            }
        } message: {
            Text(WorkspacePresentation.removalDetail(profile: profile, active: workspace.activeProfiles, primary: workspace.menuAirport))
        }.sheet(isPresented: $historyExpanded, onDismiss: {
            if historyFromLink { historyFocused = true } else { moreFocused = true }
        }) { SourceHistoryView(workspace: workspace, profile: profile) }
            .onChange(of: editorFocusReturnID) { _, destination in
                clearConfigurationFocus()
                guard destination == profile.id else { return }
                let generation = configurationFocusGeneration
                // Wait for the sheet's responder restoration to finish. Read the
                // live binding so opening another airport cancels this request.
                DispatchQueue.main.async {
                    guard configurationFocusGeneration == generation,
                          editorFocusReturnID == profile.id, workspace.page == .airports else { return }
                    if editingFromForecast && model.resetRule.kind == .none && model.samplingForecastResult.estimate == nil {
                        resetActionFocusToken = UUID()
                    } else {
                        configurationFocused = true
                    }
                    editingFromForecast = false
                }
            }
            .onChange(of: workspace.page) { _, _ in clearConfigurationFocus() }
            .onDisappear { clearConfigurationFocus() }
    }
    private func clearConfigurationFocus() {
        configurationFocusGeneration = UUID()
        configurationFocused = false
    }
    private var topLine: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Text(profile.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.tail).help(profile.name)
                if workspace.menuAirport == profile.id {
                    Text("主力").font(.system(size: 9, weight: .medium)).foregroundStyle(Magpie.accent)
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(Magpie.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 4)).fixedSize()
                }
            }.frame(maxWidth: .infinity, alignment: .leading).layoutPriority(-1)
            Button { statusExpanded.toggle() } label: {
                HStack(spacing: 4) {
                    Circle().fill(statusColor).frame(width: 5, height: 5)
                    Text(presentation.status)
                        .font(.system(size: 11, weight: statusFocused ? .medium : .regular))
                        .foregroundStyle(model.error != nil && profile.enabled && !model.busy ? Magpie.danger : statusFocused ? .primary : .secondary)
                }
            }.buttonStyle(.plain).fixedSize().focusable().focused($statusFocused)
                .focusEffectDisabled()
                .workspaceKeyboardActivation { statusExpanded.toggle() }
                .help(presentation.statusDetail)
                .accessibilityLabel("\(profile.name)\(presentation.status)，查看详情")
                .popover(isPresented: $statusExpanded, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(presentation.status).font(.system(size: 12, weight: .medium))
                        Text(presentation.statusDetail).font(.system(size: 11))
                        Text(model.latest.map { "上次成功 \(PanelFormat.syncTime($0.date))" } ?? "尚无成功读数").font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("关闭") { statusExpanded = false; statusFocused = true }.keyboardShortcut(.cancelAction)
                            .focusable().focused($statusCloseFocused)
                            .workspaceFocusCue(statusCloseFocused)
                            .workspaceKeyboardActivation { statusExpanded = false; statusFocused = true }
                    }.padding(14).frame(width: 280).onAppear { statusCloseFocused = true }
                }
                .onChange(of: statusExpanded) { _, visible in if !visible { statusFocused = true } }
            Text(presentation.successTime)
                .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                .accessibilityLabel(model.latest.map { "上次成功 \(PanelFormat.syncTime($0.date))" } ?? "尚无成功读数")
            Toggle("自动同步", isOn: Binding(get: { profile.enabled }, set: { value in
                beginOperation(); workspace.setEnabled(profile, value)
            })).toggleStyle(.switch).controlSize(.mini).font(.system(size: 10)).fixedSize()
                .accessibilityLabel("\(profile.name)自动同步")
            HStack(spacing: 2) {
                Button(action: sync) {
                    if model.busy { ProgressView().controlSize(.mini).frame(width: 12, height: 12) }
                    else { Image(systemName: model.error == nil ? "arrow.clockwise" : "arrow.clockwise.circle") }
                }.buttonStyle(WorkspaceIconButton()).disabled(model.busy || workspace.isDemo)
                    .focusable().focused($syncFocused).workspaceFocusCue(syncFocused)
                    .workspaceKeyboardActivation(sync)
                    .accessibilityLabel("\(model.error == nil ? "同步" : "重试同步")\(profile.name)")
                    .help(model.busy ? "正在同步" : "同步机场数据；同一订阅地址至少间隔72小时")
                Button { clearConfigurationFocus(); editingFromForecast = false; edit() } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(WorkspaceIconButton()).focusable()
                    .focused($configurationFocused).accessibilityLabel("配置\(profile.name)")
                    .help("配置机场")
                    .workspaceFocusCue(configurationFocused)
                    .workspaceKeyboardActivation { clearConfigurationFocus(); editingFromForecast = false; edit() }
                WorkspaceActionMenu(label: "\(profile.name)更多操作", actions: [
                    WorkspaceMenuAction(title: "设为主力机场", enabled: workspace.menuAirport != profile.id) {
                        beginOperation(); workspace.menuAirport = profile.id
                    },
                    WorkspaceMenuAction(title: "查看来源历史") { historyFromLink = false; historyExpanded = true },
                    WorkspaceMenuAction(title: "移除机场…", separatorBefore: true) { beginOperation(); confirmArchive = true }
                ], focus: $moreFocused) {
                    if !historyExpanded && !confirmArchive { moreFocused = true }
                }.help("主力机场、来源历史与移除")
            }
        }.frame(height: 28)
    }
    private func sync() {
        guard !model.busy, !workspace.isDemo else { return }
        beginOperation()
        let before = model.latest?.id
        Task {
            await model.refresh()
            if let waiting = model.requestWaitingMessage { announce(waiting) }
            else if model.error != nil { announce("同步失败，保留上次读数") }
            else if model.latest?.id != before { announce("\(profile.name)已同步") }
            else { announce("本次同步已结束，保留现有读数") }
        }
    }
    private var quotaSummary: some View {
        let info = model.latest?.subscription
        let reset = ResetPresentation(rule: model.resetRule, at: model.referenceDate, displayTimeZone: .current)
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("剩余流量").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(info?.remaining.map { model.trafficUnit.text($0) } ?? "—")
                        .font(.system(size: 22, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(BasicQuotaPresentation(model: model).risk.color)
                    if presentation.usesOldReading {
                        Text("上次读数").font(.system(size: 9)).foregroundStyle(.secondary).fixedSize()
                    }
                }
                if let info, info.total > 0, let remaining = info.remaining {
                    GeometryReader { geometry in
                        Capsule().fill(Magpie.pill).overlay(alignment: .leading) {
                            Capsule().fill(Magpie.accent).frame(width: geometry.size.width * min(1, max(0, Double(remaining) / Double(info.total))))
                        }
                    }.frame(height: 3).accessibilityHidden(true)
                    Text("已用 \(model.trafficUnit.text(info.total - remaining)) / \(model.trafficUnit.text(info.total))")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(info == nil ? "等待首次读取" : "总额未提供").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Magpie.line).frame(width: 1, height: 64)
            VStack(alignment: .leading, spacing: 8) {
                Text("下次重置").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(reset.value).font(.system(size: 12, weight: .medium)).lineLimit(1).help(reset.detail)
                if model.resetRule.kind == .none {
                    Text("可在配置中设置").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Magpie.line).frame(width: 1, height: 64)
            VStack(alignment: .leading, spacing: 8) {
                Text(model.expired ? "已到期" : "到期时间").font(.system(size: 11)).foregroundStyle(model.expired ? Magpie.danger : .secondary)
                Text(info?.expiry.map { NativeFormat.day($0) } ?? "未提供")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(model.expired ? Magpie.danger : .primary).lineLimit(1)
                if info?.expiry == nil {
                    Text("订阅未提供到期日期").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: 68, alignment: .top)
    }
}

struct ArchivedAirportRow: View {
    @ObservedObject var workspace: AirportWorkspace
    let profile: AirportProfile
    let restore: () -> Void
    @State private var showHistory = false
    @FocusState private var historyFocused: Bool
    var body: some View {
        let model = workspace.model(for: profile)
        HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(profile.name).font(.system(size: 12, weight: .medium)).lineLimit(1).help(profile.name)
                    Text(model.latest?.subscription.remaining.map { "保留读数 \(model.trafficUnit.text($0)) · 历史已保留" } ?? "尚无可用余额 · 已有记录保留")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Text((model.latest.map { "上次成功 \(NativeFormat.day($0.date)) \(NativeFormat.time($0.date))" } ?? "尚无成功读数") + " · 原自动同步\(profile.enabled ? "已开启" : "已暂停")")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                Button("查看历史") { showHistory = true }.buttonStyle(WorkspaceButton(quiet: true))
                    .fixedSize().focusable().focused($historyFocused).accessibilityLabel("查看\(profile.name)历史")
                    .workspaceFocusCue(historyFocused)
                    .workspaceKeyboardActivation { showHistory = true }
                Button("恢复", action: restore).buttonStyle(WorkspaceButton()).fixedSize()
                    .disabled(workspace.catalogBlocked).accessibilityLabel("恢复\(profile.name)")
        }.padding(14)
            .sheet(isPresented: $showHistory, onDismiss: { historyFocused = true }) { SourceHistoryView(workspace: workspace, profile: profile) }
    }
}
