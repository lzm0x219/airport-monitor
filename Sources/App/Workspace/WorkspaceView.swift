import SwiftUI

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

struct AirportEditorRequest: Identifiable { let id = UUID(); let profile: AirportProfile? }
