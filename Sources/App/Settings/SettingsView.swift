import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var workspace: AirportWorkspace
    @Binding var state: SettingsPageState
    @ObservedObject var updater: AppUpdater
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var timeZoneError: String?
    @State private var menuError: String?
    @State private var notificationError: String?
    @State private var changingNotifications = false
    @State private var recovering: UUID?
    @FocusState private var focusedTab: SettingsSection?
    @State private var hoveredTab: SettingsSection?
    private var model: MonitorModel? { workspace.menuModel ?? workspace.browsingProfile.map { workspace.model(for: $0) } }
    private var unit: TrafficUnit { model?.trafficUnit ?? TrafficUnit(rawValue: workspace.defaults.string(forKey: "trafficUnit") ?? "") ?? .gb }
    private var menu: MenuDisplay { model?.menuDisplay ?? MenuDisplay(rawValue: workspace.defaults.string(forKey: "menuDisplay") ?? "") ?? .iconAndBalance }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                sectionTabs
                Spacer(minLength: 8)
                Text("更改即时生效").font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(height: 28)
            sectionPage
        }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 8)
            .focusEffectDisabled()
            .task {
                if !state.restoredSelection {
                    if let section = workspace.savedSettingsSection { state.section = section }
                    state.restoredSelection = true
                }
                await workspace.refreshNotificationAuthorization()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await workspace.refreshNotificationAuthorization() }
                if !workspace.isDemo { login = SMAppService.mainApp.status == .enabled }
            }
            .alert("隔离损坏的本地数据？", isPresented: Binding(get: { recovering != nil }, set: { if !$0 { recovering = nil } })) {
                Button("取消", role: .cancel) { recovering = nil }
                Button("隔离并重新开始") {
                    if let id = recovering, let profile = workspace.profiles.first(where: { $0.id == id }) {
                        Task { await workspace.model(for: profile).recoverHistory() }
                    }
                    recovering = nil
                }
            } message: { Text("原文件保留为 .corrupt 副本；下一次成功同步建立新基线。") }
    }

    private var sectionTabs: some View {
        HStack(spacing: 2) {
            ForEach(SettingsSection.allCases) { section in
                Button { select(section) } label: {
                    HStack(spacing: 4) {
                        Text(section.title)
                        if section == .privacy, blockedProfileCount > 0 {
                            Circle().fill(Magpie.warning).frame(width: 5, height: 5).accessibilityHidden(true)
                        }
                    }.font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(state.section == section ? Color.primary : hoveredTab == section ? Color.primary.opacity(0.8) : .secondary)
                        .padding(.horizontal, 9).frame(height: 28)
                        .background(state.section == section ? Magpie.pill : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).focusable().focused($focusedTab, equals: section)
                    .focusEffectDisabled().workspaceKeyboardActivation { select(section) }
                    .onHover { hoveredTab = $0 ? section : nil }
                    .onMoveCommand { direction in
                        guard direction == .left || direction == .right,
                              let index = SettingsSection.allCases.firstIndex(of: section) else { return }
                        let target = min(SettingsSection.allCases.count - 1, max(0, index + (direction == .left ? -1 : 1)))
                        focusAndSelect(SettingsSection.allCases[target])
                    }
                    .onKeyPress(.home) { focusAndSelect(.general); return .handled }
                    .onKeyPress(.end) { focusAndSelect(.about); return .handled }
                    .accessibilityLabel(section.title)
                    .accessibilityValue(state.section == section ? "当前分类" : "未选中")
                    .accessibilityHint(section == .privacy && blockedProfileCount > 0 ? "有\(blockedProfileCount)个机场的本地数据需要处理" : "")
                    .accessibilityAddTraits(state.section == section ? [.isSelected] : [])
            }
        }.fixedSize().accessibilityElement(children: .contain).accessibilityLabel("设置分类")
    }

    private var blockedProfileCount: Int {
        workspace.profiles.filter { workspace.model(for: $0).storageBlocked }.count
    }
    private func select(_ section: SettingsSection) {
        focusedTab = section
        guard state.section != section else { return }
        state.section = section
        workspace.rememberSettingsSection(section)
    }
    private func focusAndSelect(_ section: SettingsSection) {
        select(section); focusedTab = section
    }
    private var sectionPage: some View {
        let section = state.section
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch section {
                case .general: generalPage
                case .menuBar: menuBarPage
                case .sync: syncPage
                case .privacy: privacyPage
                case .about: aboutPage
                }
            }.frame(maxWidth: .infinity, alignment: .topLeading).scrollTargetLayout().padding(.bottom, 12)
        }.id(section)
            .scrollPosition(id: Binding(get: { state.scrollAnchors[section] }, set: { value in
                guard state.section == section else { return }
                state.scrollAnchors[section] = value
            }), anchor: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var generalPage: some View {
        group("显示") {
            setting("外观", separator: true) {
                WorkspaceSegments(title: "外观", selection: Binding(get: { workspace.appearanceMode }, set: { workspace.setAppearance($0) }),
                                  options: AppAppearance.allCases.map { ($0.label, $0) })
            }
            setting("流量单位") {
                WorkspaceSegments(title: "流量单位", selection: Binding(get: { unit }, set: { workspace.setDisplay(unit: $0) }),
                                  options: TrafficUnit.allCases.map { ($0.label, $0) })
            }
        }
        group("启动") {
            setting("登录时启动", detail: workspace.isDemo || workspace.isIsolatedReview ? "隔离预览不更改登录项。" : nil) {
                Toggle("登录时启动", isOn: Binding(get: { login }, set: setLogin))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini).disabled(workspace.isDemo || workspace.isIsolatedReview)
                    .accessibilityLabel("登录时启动")
            }
            inlineError(loginError)
        }
    }
    private var menuBarPage: some View {
        group("菜单栏") {
            setting("面板布局", separator: true) {
                WorkspaceSegments(title: "菜单栏布局", selection: Binding(get: { workspace.menuPanelLayout }, set: { workspace.setMenuPanelLayout($0) }),
                                  options: MenuPanelLayout.allCases.map { ($0.label, $0) })
            }
            setting("显示内容", separator: workspace.activeProfiles.count > 1) {
                WorkspaceSegments(title: "菜单栏显示", selection: Binding(get: { menu }, set: { workspace.setDisplay(menu: $0) }),
                                  options: MenuDisplay.allCases.map { ($0.label, $0) })
            }
            if workspace.activeProfiles.count > 1 {
                setting("主力机场") {
                    CompactChoice(title: "菜单栏机场", selection: Binding(get: { workspace.menuAirport }, set: { value in
                        menuError = nil
                        workspace.menuAirport = value
                        if workspace.menuAirport != value { menuError = workspace.message ?? "主力机场未能保存，原设置保持。" }
                    }),
                                  options: workspace.activeProfiles.map { ($0.name, Optional($0.id)) }).frame(width: 190)
                }
            }
            inlineError(menuError)
        }
    }
    @ViewBuilder private var syncPage: some View {
        group("同步与统计") {
            setting("自动同步间隔", detail: "同一地址至少间隔72小时；手动刷新和失败重试也受限。", separator: true) {
                CompactChoice(title: "同步间隔", selection: Binding(get: { workspace.interval }, set: { workspace.setInterval($0) }),
                              options: [("72 小时", 4320), ("7 天", 10080)]).frame(width: 120)
            }
            setting("统计时区", detail: workspace.isDemo ? "设计预览不更改统计时区。" : "固定使用所选时区，旅行时不自动改变。") {
                statisticsTimeZonePicker.frame(width: 190).disabled(workspace.isDemo)
            }
            Text("更改后按新时区重新分日；原始读数时间和机场重置规则保留。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.bottom, 9)
            inlineError(timeZoneError)
        }
        group("通知") {
            setting("系统通知", detail: "低余量、预计不足与到期；各机场独立选择。") {
                Toggle("系统通知", isOn: Binding(get: { workspace.systemNotificationsEnabled }, set: setNotifications))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .disabled(workspace.isDemo || changingNotifications).accessibilityLabel("系统通知")
                    .accessibilityHint(changingNotifications ? "正在更新通知权限，请稍候。" : "低余量、预计不足与到期提醒的总开关。")
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(workspace.isDemo ? "设计预览不申请权限或发送通知。" : changingNotifications ? "正在更新通知权限…" : workspace.notificationAuthorizationStatus)
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("系统通知设置") { openNotificationSettings() }
                    .buttonStyle(CompactButton(quiet: true)).disabled(workspace.isDemo)
            }.padding(.bottom, 7)
            inlineError(notificationError ?? workspace.notificationPermissionError)
        }
    }
    @ViewBuilder private var privacyPage: some View {
        group("本地数据与隐私") {
            Text(SettingsExplanation.privacy.text)
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
        }
        if blockedProfileCount > 0 {
            group("需要处理的数据") {
            ForEach(workspace.profiles.filter { workspace.model(for: $0).storageBlocked }) { profile in
                VStack(alignment: .leading, spacing: 7) {
                    Text("\(profile.name)的本地数据受保护").font(.system(size: 12, weight: .medium))
                    Text("原文件无法读取，已暂停采样。隔离后可重新同步，原文件保留。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("隔离损坏文件…", role: .destructive) { recovering = profile.id }
                        .buttonStyle(CompactButton()).disabled(workspace.isDemo || workspace.model(for: profile).busy)
                }.padding(.vertical, 4)
            }
            }
        }
    }
    @ViewBuilder private var aboutPage: some View {
        group("关于") {
            HStack(alignment: .top, spacing: 12) {
                Image("MenuBarIcon").renderingMode(.template).resizable().frame(width: 32, height: 32).accessibilityHidden(true)
                Text(SettingsExplanation.about.text).font(.system(size: 12)).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.vertical, 12)
        }
        group("软件更新") {
            setting("自动检查更新", detail: updater.isConfigured ? "定期检查新版本；更新下载后可选择何时重启。" : "当前版本无法检查更新。", separator: true) {
                Toggle("自动检查更新", isOn: Binding(get: { updater.automaticallyChecks }, set: updater.setAutomaticallyChecks))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .disabled(!updater.isConfigured).accessibilityLabel("自动检查更新")
            }
            setting("检查更新") {
                HStack(spacing: 8) {
                    if updater.restartAvailable {
                        Button("重新启动并更新") { updater.restartToInstall() }.buttonStyle(WorkspaceButton())
                    }
                    Button("检查更新") { updater.checkNow() }.buttonStyle(WorkspaceButton(quiet: true))
                        .disabled(!updater.canCheck)
                }
            }
        }
    }

    private var statisticsTimeZonePicker: some View {
        Menu {
            Button("当前系统：\(TimeZone.current.identifier)") { setTimeZone(TimeZone.current.identifier) }
            Divider()
            ForEach(timeZoneRegions, id: \.self) { region in
                Menu(regionName(region)) {
                    ForEach(TimeZone.knownTimeZoneIdentifiers.filter { $0.hasPrefix(region + "/") }, id: \.self) { identifier in
                        Button { setTimeZone(identifier) } label: {
                            if identifier == workspace.statisticsTimeZoneIdentifier { Label(identifier, systemImage: "checkmark") }
                            else { Text(identifier) }
                        }
                    }
                }
            }
            Button("UTC") { setTimeZone("UTC") }
        } label: { CompactMenuLabel(title: workspace.statisticsTimeZoneIdentifier, fillsWidth: true) }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .accessibilityLabel("统计时区").accessibilityValue(workspace.statisticsTimeZoneIdentifier).help(workspace.statisticsTimeZoneIdentifier)
    }
    private var timeZoneRegions: [String] { Array(Set(TimeZone.knownTimeZoneIdentifiers.compactMap { $0.contains("/") ? String($0.split(separator: "/")[0]) : nil })).sorted() }
    private func regionName(_ region: String) -> String {
        ["Africa": "非洲", "America": "美洲", "Antarctica": "南极洲", "Arctic": "北极", "Asia": "亚洲", "Atlantic": "大西洋", "Australia": "澳大利亚", "Europe": "欧洲", "Indian": "印度洋", "Pacific": "太平洋"][region] ?? region
    }
    private func setTimeZone(_ identifier: String) {
        timeZoneError = nil
        if !workspace.setStatisticsTimeZone(identifier) { timeZoneError = workspace.message ?? "统计时区未能保存，原设置保持。" }
    }
    private func setNotifications(_ enabled: Bool) {
        guard !changingNotifications, !workspace.isDemo else { return }
        notificationError = nil; changingNotifications = true
        Task { await workspace.setReminders(enabled); changingNotifications = false }
    }
    private func openNotificationSettings() {
        guard !workspace.isDemo, let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        notificationError = NSWorkspace.shared.open(url) ? nil : "无法打开系统设置。请在系统设置 → 通知中找到 Airport Monitor。"
    }
    private func setLogin(_ enabled: Bool) {
        guard !workspace.isDemo, !workspace.isIsolatedReview else { return }
        loginError = nil
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            let status = SMAppService.mainApp.status
            login = status == .enabled
            if status == .requiresApproval { loginError = "需要在系统设置 → 通用 → 登录项中允许启动。" }
        } catch {
            loginError = "登录启动未能更改：\(error.localizedDescription)"
            login = SMAppService.mainApp.status == .enabled
        }
    }
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 2)
            VStack(alignment: .leading, spacing: 0, content: content)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Magpie.surface, in: RoundedRectangle(cornerRadius: 9))
        }.id(title)
    }
    private func setting<Content: View>(_ title: String, detail: String? = nil, separator: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12))
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            content().font(.system(size: 12)).fixedSize(horizontal: true, vertical: false)
        }.frame(minHeight: 40).padding(.vertical, 3)
            .overlay(alignment: .bottom) {
                if separator { Rectangle().fill(Magpie.line).frame(height: 1) }
            }
    }
    @ViewBuilder private func inlineError(_ text: String?) -> some View {
        if let text {
            Label(text, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(Magpie.warning)
                .fixedSize(horizontal: false, vertical: true).padding(.bottom, 8).accessibilityLabel("错误：\(text)")
        }
    }
}

private enum SettingsExplanation {
    case privacy, about
    var text: String {
        switch self {
        case .privacy:
            return "订阅链接只保存在本机钥匙串，不写入本地记录或错误输出。\n\n各机场独立保存订阅与本地数据；移除可以恢复。更新同一来源的链接保留历史，明确更换数据来源才建立独立记录，旧记录仍保留。\n\n余量来自服务端的总额、上传和下载计数，可能包含多设备消耗与服务商倍率，不等于本机网速。总额未知时不推断余量或百分比。\n\n统计从添加后积累，缺失日期不补造；预测为估计。同步失败保留最后成功读数。检查软件更新时会连接 GitHub，不发送订阅链接。没有分析服务、遥测或云同步。"
        case .about:
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "本机构建"
            let versionLine = build == version ? "版本 \(version)" : "版本 \(version) · \(build)"
            return "Airport Monitor\n\(versionLine)\n\n在菜单栏随时查看机场余量，在主窗口回顾用量与预测。多个机场独立管理，不合并不同套餐额度。"
        }
    }
}
