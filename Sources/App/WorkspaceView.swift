import SwiftUI
import AppKit

struct SettingsPageState {
    var section: SettingsSection = .general
    var scrollAnchors: [SettingsSection: String] = [:]
    var restoredSelection = false
}

struct WorkspaceView: View {
    @ObservedObject var workspace: AirportWorkspace
    @ObservedObject var toolbarState: WorkspaceToolbarState
    @State private var showArchive = false
    @State private var editorSession: AirportEditingSession?
    @State private var presentedEditor: AirportEditingSession?
    @State private var returnToEditor = false
    @State private var returnedEditor: UUID?
    @State private var connectionSession: AirportConnectionSession?
    @State private var settingsState = SettingsPageState()
    @State private var airportScrollAnchor: UUID?
    @State private var archivedScrollAnchor: UUID?
    @State private var connectionReturnAnchor: UUID?
    @State private var connectionScrollID = UUID()
    @FocusState private var archiveFocused: Bool

    private var orderedProfiles: [AirportProfile] {
        let active = workspace.activeProfiles
        return active.filter { $0.id == workspace.menuAirport } + active.filter { $0.id != workspace.menuAirport }
    }
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                airportPage
                    .opacity(workspace.page == .airports ? 1 : 0)
                    .allowsHitTesting(workspace.page == .airports).disabled(workspace.page != .airports)
                    .accessibilityHidden(workspace.page != .airports)
                if workspace.page == .settings {
                    SettingsView(workspace: workspace, state: $settingsState)
                }
            }.frame(maxWidth: 960).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if workspace.isDemo || workspace.isIsolatedReview {
                Text(workspace.isIsolatedReview ? "隔离验证 · 合成订阅与历史，不发送系统通知" : "设计预览 · 合成数据，不读取或保存订阅")
                    .font(.system(size: 10)).foregroundStyle(.secondary).frame(height: 22)
            }
        }.background(Magpie.background).tint(Magpie.accent).frame(minWidth: 680, minHeight: 520)
            .focusEffectDisabled()
            .sheet(item: $presentedEditor, onDismiss: editorDidDismiss) { session in
                AirportEditor(workspace: workspace, session: session,
                    onSaved: { presentedEditor = nil; announce(workspace.message ?? "配置已保存") },
                    onSettings: {
                        returnToEditor = true
                        settingsState.section = .sync; settingsState.restoredSelection = true
                        workspace.rememberSettingsSection(.sync)
                        presentedEditor = nil; clearFeedback(); workspace.page = .settings
                    })
            }
            .onChange(of: toolbarState.addRequest) { _, _ in
                guard workspace.page == .airports, !workspace.catalogBlocked, presentedEditor == nil else { return }
                beginConnection()
            }
            .onChange(of: connectionSession != nil) { _, active in toolbarState.connectionActive = active }
            .onChange(of: workspace.message) { _, value in if let value { announce(value) } }
            .onChange(of: workspace.page) { _, page in
                if page == .settings { clearFeedback() }
                else if returnToEditor {
                    returnToEditor = false
                    presentedEditor = editorSession
                }
            }
    }
    private var airportPage: some View {
        VStack(spacing: 8) {
            if showArchive || workspace.profiles.contains(where: \.archived) {
                HStack {
                    if showArchive {
                        Text("已移除机场 · \(workspace.profiles.filter(\.archived).count)")
                            .font(.system(size: 12, weight: .medium))
                    }
                    Spacer()
                    Button { toggleArchive() } label: {
                        Text(showArchive ? "返回主页面" : "已移除 (\(workspace.profiles.filter(\.archived).count))")
                    }.buttonStyle(WorkspaceButton(quiet: true)).fixedSize().focusable().focused($archiveFocused)
                        .workspaceFocusCue(archiveFocused)
                        .workspaceKeyboardActivation { toggleArchive() }
                }.frame(height: 30)
            }
            ScrollView {
                LazyVStack(spacing: 12) {
                    if let connectionSession, !showArchive {
                        InlineAirportConnection(workspace: workspace, session: connectionSession,
                            onCancel: {
                                self.connectionSession = nil
                                airportScrollAnchor = connectionReturnAnchor ?? orderedProfiles.first?.id
                                DispatchQueue.main.async {
                                    guard self.connectionSession == nil, workspace.page == .airports,
                                          !showArchive, presentedEditor == nil else { return }
                                    toolbarState.addFocusRequest = UUID()
                                }
                            },
                            onAdded: { id in
                                self.connectionSession = nil; airportScrollAnchor = id; returnedEditor = nil
                                announce("机场已添加，开始积累用量记录")
                                DispatchQueue.main.async {
                                    guard workspace.page == .airports, !showArchive,
                                          presentedEditor == nil, self.connectionSession == nil else { return }
                                    returnedEditor = id
                                }
                            }).id(connectionScrollID)
                    }
                    if showArchive {
                        Text("历史与配置均已保留，不参与同步和提醒。恢复后沿用原自动同步偏好。")
                            .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        if workspace.profiles.contains(where: \.archived) {
                            VStack(spacing: 0) {
                                ForEach(workspace.profiles.filter(\.archived)) { profile in
                                    ArchivedAirportRow(workspace: workspace, profile: profile) { restore(profile) }
                                        .id(profile.id)
                                    if profile.id != workspace.profiles.last(where: \.archived)?.id {
                                        Divider().padding(.horizontal, 14)
                                    }
                                }
                            }.background(Magpie.surface, in: RoundedRectangle(cornerRadius: 10))
                            Text("恢复不会绕过72小时限频。成功读取前保留上次读数，未监测期间不补写每日用量。")
                                .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        ForEach(orderedProfiles) { profile in
                            AirportCard(workspace: workspace, model: workspace.model(for: profile), profile: profile,
                                edit: {
                                    clearFeedback(); returnedEditor = nil
                                    let session = AirportEditingSession(workspace: workspace, profile: profile)
                                    editorSession = session; presentedEditor = session
                                },
                                announce: announce, beginOperation: clearFeedback,
                                onArchived: { DispatchQueue.main.async { if workspace.page == .airports { archiveFocused = true } } },
                                editorFocusReturnID: $returnedEditor).id(profile.id)
                        }
                    }
                    if (showArchive ? workspace.profiles.filter(\.archived) : orderedProfiles).isEmpty {
                        EmptyWorkspace(title: showArchive ? "暂无已移除机场" : "添加机场，开始记录",
                            detail: showArchive ? "移除只会停止监测，配置和历史可随时恢复。" : "连接订阅后查看剩余流量；用量统计从添加后开始积累。",
                            actionTitle: showArchive ? "返回机场" : "连接订阅", actionDisabled: workspace.catalogBlocked) {
                                if showArchive { toggleArchive() } else { beginConnection() }
                            }
                    }
                }.scrollTargetLayout().padding(.bottom, 16)
            }
            // Active and archived rows may share an airport identity, but they
            // must never share a lazy-list view identity or cached row type.
            .id(showArchive ? "archived-airports" : "active-airports")
            .scrollPosition(id: Binding(get: { showArchive ? archivedScrollAnchor : airportScrollAnchor }, set: { id in
                guard let id else { return }
                if showArchive { archivedScrollAnchor = id } else { airportScrollAnchor = id }
            }), anchor: .top)
        }.padding(.horizontal, 16).padding(.top, 2)
    }
    private func toggleArchive() {
        clearFeedback(); showArchive.toggle()
        DispatchQueue.main.async {
            guard workspace.page == .airports else { return }
            if showArchive || workspace.profiles.contains(where: \.archived) { archiveFocused = true }
            else { toolbarState.addFocusRequest = UUID() }
        }
    }
    private func restore(_ profile: AirportProfile) {
        clearFeedback()
        guard workspace.archive(profile, archived: false) else { return }
        showArchive = false; airportScrollAnchor = profile.id; returnedEditor = nil
        announce("已恢复\(profile.name)，\(profile.enabled ? "按限频核对读数" : "自动同步仍暂停")")
        DispatchQueue.main.async {
            guard workspace.page == .airports, !showArchive, presentedEditor == nil else { return }
            returnedEditor = profile.id
        }
    }
    private func beginConnection() {
        clearFeedback(); showArchive = false
        if connectionSession == nil {
            connectionReturnAnchor = airportScrollAnchor
            connectionSession = AirportConnectionSession(workspace: workspace)
        }
        airportScrollAnchor = connectionScrollID
    }
    private func announce(_ text: String) { toolbarState.announce(text) }
    private func clearFeedback() { toolbarState.clearFeedback() }
    private func editorDidDismiss() {
        guard !returnToEditor, presentedEditor == nil else { return }
        returnedEditor = editorSession?.profile?.id
        editorSession = nil
    }
}

/// The native toolbar and page have separate hosting roots. Only header events
/// and presentation state cross that boundary; the page owns the add session.
@MainActor
final class WorkspaceToolbarState: ObservableObject {
    @Published var addRequest = UUID()
    @Published var addFocusRequest = UUID()
    @Published var connectionActive = false
    @Published var feedback: String?
    var feedbackHovered = false
    var feedbackFocused = false
    private var feedbackToken = UUID()

    func announce(_ text: String) { feedback = text; scheduleFeedbackDismissal() }
    func clearFeedback() { feedback = nil; feedbackToken = UUID() }
    func scheduleFeedbackDismissal() {
        let token = UUID(); feedbackToken = token
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, token == feedbackToken, !feedbackHovered, !feedbackFocused else { return }
            feedback = nil
        }
    }
}

struct WorkspaceBrand: View {
    var body: some View {
        HStack(spacing: 6) {
            Image("MenuBarIcon").renderingMode(.template).resizable().frame(width: 18, height: 18)
            Text("Airport Monitor")
                .font(.system(size: 13, weight: .semibold)).tracking(0.13)
                .foregroundStyle(.primary).lineLimit(1)
        }.fixedSize().frame(height: 32)
    }
}

struct WorkspaceToolbarFeedback: View {
    @ObservedObject var state: WorkspaceToolbarState
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 4) {
            if let feedback = state.feedback {
                Text(feedback).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail).help(feedback)
                Button { state.clearFeedback() } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                    .buttonStyle(.plain).focused($focused).accessibilityLabel("关闭操作提示")
            }
        }.frame(width: 110, height: 28, alignment: .leading)
            .onHover { state.feedbackHovered = $0; if !$0 { state.scheduleFeedbackDismissal() } }
            .onChange(of: focused) { _, value in
                state.feedbackFocused = value
                if !value { state.scheduleFeedbackDismissal() }
            }
            .accessibilityElement(children: .contain)
    }
}

struct WorkspaceNavigationTabs: View {
    @ObservedObject var workspace: AirportWorkspace
    @FocusState private var focusedPage: WorkspacePage?
    @State private var hoveredPage: WorkspacePage?

    var body: some View {
        HStack(spacing: 2) {
            tab("机场", page: .airports)
        }.padding(2).frame(height: 32).fixedSize()
            .focusEffectDisabled().accessibilityElement(children: .contain)
            .accessibilityLabel("页面切换")
    }
    private func tab(_ title: String, page: WorkspacePage) -> some View {
        Button { workspace.page = page } label: {
            Text(title).font(.system(size: 12, weight: workspace.page == page ? .semibold : .medium))
                .foregroundStyle(workspace.page == page ? .primary : .secondary)
                .padding(.horizontal, 14).frame(height: 28)
                .background(workspace.page == page ? Magpie.surface : hoveredPage == page ? Magpie.pill : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).focusable().focused($focusedPage, equals: page).focusEffectDisabled()
            .workspaceKeyboardActivation { workspace.page = page }
            .onHover { hoveredPage = $0 ? page : nil }
            .accessibilityLabel(title)
            .accessibilityValue(workspace.page == page ? "当前页面" : "未选中")
            .accessibilityAddTraits(workspace.page == page ? [.isSelected] : [])
    }
}

struct WorkspaceToolbarActions: View {
    @ObservedObject var workspace: AirportWorkspace
    @ObservedObject var state: WorkspaceToolbarState
    @FocusState private var addFocused: Bool
    @FocusState private var settingsFocused: Bool
    var body: some View {
        HStack(spacing: 4) {
            Button { requestAdd() } label: {
                Image(systemName: "plus")
            }.buttonStyle(WorkspaceIconButton())
                .accessibilityLabel("添加机场")
                .disabled(workspace.catalogBlocked || workspace.page != .airports)
                .help("添加机场：连接订阅并预览信息")
                .focusable().focused($addFocused)
                .workspaceKeyboardActivation { requestAdd() }
                .opacity(workspace.page == .airports ? 1 : 0)
                .accessibilityHidden(workspace.page != .airports)
            Button { workspace.page = .settings } label: { Image(systemName: "gearshape") }
                .buttonStyle(WorkspaceIconButton()).help("设置")
                .focusable().focused($settingsFocused)
                .workspaceKeyboardActivation { workspace.page = .settings }
                .accessibilityLabel("设置")
                .accessibilityValue(workspace.page == .settings ? "当前页面" : "未选中")
                .accessibilityAddTraits(workspace.page == .settings ? [.isSelected] : [])
        }.fixedSize().frame(height: 32).focusEffectDisabled()
            .onChange(of: state.addFocusRequest) { _, _ in
                guard workspace.page == .airports, !workspace.catalogBlocked else { return }
                addFocused = true
            }
    }
    private func requestAdd() {
        guard workspace.page == .airports, !workspace.catalogBlocked else { return }
        state.addRequest = UUID()
    }
}

private struct AirportCard: View {
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

private struct ArchivedAirportRow: View {
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

private struct SourceHistoryView: View {
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

struct AirportEditorRequest: Identifiable { let id = UUID(); let profile: AirportProfile? }
