import AppKit
import SwiftUI
import Combine
#if SWIFT_PACKAGE
import TrafficCore
#endif

struct SyncAttempt: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let subscription: Subscription?
    let message: String?
    var succeeded: Bool { subscription != nil && message == nil }
}

struct SyncAttemptStore {
    let url: URL
    func load() throws -> [SyncAttempt] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([SyncAttempt].self, from: Data(contentsOf: url))
    }
    func save(_ attempts: [SyncAttempt]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(attempts).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

struct AirportEditorDraft: Equatable {
    var name = ""
    var plan = ""
    var subscription = ""
    var threshold: Double = 10
    var resetRule = ResetRule()

    func canSave(requiresSubscription: Bool) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (!requiresSubscription || !subscription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) &&
        threshold.isFinite && threshold > 0 && threshold <= 1_000_000 &&
        (try? resetRule.validate()) != nil
    }
}

struct AirportProfile: Codable, Identifiable {
    let id: UUID
    var historyID: String
    let credentialAccount: String
    var name: String
    var plan: String
    var enabled: Bool
    var archived: Bool
}

struct AirportCatalog: Codable {
    var version = 1
    var profiles: [AirportProfile]
    var menuAirport: UUID?
    func validate() throws {
        guard [1, 2].contains(version),
              Set(profiles.map(\.id)).count == profiles.count,
              Set(profiles.map(\.credentialAccount)).count == profiles.count,
              profiles.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  UUID(uuidString: $0.historyID) != nil && !$0.credentialAccount.isEmpty }) else { throw TrafficError.storage }
    }
}

enum WorkspacePage: String, CaseIterable, Identifiable {
    case airports = "机场", settings = "设置"
    var id: String { rawValue }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, menuBar, sync, privacy, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "通用"
        case .menuBar: "菜单栏"
        case .sync: "同步与提醒"
        case .privacy: "数据与隐私"
        case .about: "关于"
        }
    }
}

enum AppAppearance: String, CaseIterable {
    case system, light, dark
    var label: String { switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" } }
    var native: NSAppearance? { switch self { case .system: nil; case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua) } }
}

enum MenuPanelLayout: String, CaseIterable {
    case overview, magpie
    var label: String { self == .overview ? "平面布局" : "分区卡片" }
}

@MainActor
final class AirportWorkspace: ObservableObject {
    @Published private(set) var profiles: [AirportProfile] = []
    @Published var menuAirport: UUID? { didSet { persist() } }
    @Published var browsingAirport: UUID?
    @Published var page: WorkspacePage = .airports
    @Published private(set) var appearanceMode: AppAppearance = .system
    @Published private(set) var menuPanelLayout: MenuPanelLayout = .magpie
    @Published var panelExplanationOpen = false
    @Published var message: String?
    @Published private(set) var notificationAuthorizationStatus = "尚未申请权限"
    @Published private(set) var notificationPermissionError: String?
    @Published private(set) var catalogBlocked = false
    let isDemo: Bool
    let isIsolatedReview: Bool
    let defaults: UserDefaults
    private(set) var repository: NativeRepository?
    private let services: MonitorServices
    private let historyDirectory: URL
    private let startAutomatically: Bool
    private var publishing = false
    private var saving = Set<String>()
    private var confirmingPreviews = Set<ObjectIdentifier>()
    private var monitors: [UUID: MonitorModel] = [:]
    private var observations: [UUID: AnyCancellable] = [:]
    private let initialRequestAttempts = StartupRequestAttempts()
    var activeProfiles: [AirportProfile] { profiles.filter { !$0.archived } }
    var menuProfile: AirportProfile? { profiles.first { $0.id == menuAirport && !$0.archived } }
    var menuModel: MonitorModel? { menuProfile.flatMap { monitors[$0.id] } }
    var browsingProfile: AirportProfile? { profiles.first { $0.id == browsingAirport } ?? activeProfiles.first }
    var busy: Bool { monitors.values.contains { $0.busy } }
    var interval: Int { monitors.values.first?.intervalMinutes ?? SubscriptionRefreshPolicy.normalized(defaults.integer(forKey: "intervalMinutes")) }
    func model(for profile: AirportProfile) -> MonitorModel { monitors[profile.id]! }

    init(demo: Bool = false, defaults: UserDefaults = .standard, historyDirectory: URL? = nil,
         services: MonitorServices? = nil, startAutomatically: Bool = true,
         isolatedReview: Bool = false,
         checkpoint: @escaping (RepositoryCheckpoint) throws -> Void = { _ in }) {
        isDemo = demo; isIsolatedReview = isolatedReview; self.defaults = defaults
        self.services = services ?? MonitorServices.live()
        self.historyDirectory = historyDirectory ?? NativeRepository.defaultRoot
        self.startAutomatically = startAutomatically
        menuPanelLayout = demo
            ? (CommandLine.arguments.contains("--panel-layout-overview") ? .overview : .magpie)
            : MenuPanelLayout(rawValue: defaults.string(forKey: "menuPanelLayout.v1") ?? "") ?? .magpie
        appearanceMode = demo ? (CommandLine.arguments.contains("--dark") ? .dark : CommandLine.arguments.contains("--light") ? .light : .system) : AppAppearance(rawValue: defaults.string(forKey: "appearanceMode.v1") ?? "") ?? .system
        if demo { makeDemo(); return }
        do {
            let store = try NativeRepository(root: self.historyDirectory, defaults: defaults, services: self.services, checkpoint: checkpoint)
            repository = store
            publishing = true; profiles = store.snapshot.catalog.profiles; menuAirport = store.snapshot.catalog.menuAirport
            for p in profiles { attach(makeMonitor(p, automatically: startAutomatically), to: p.id) }
            publishing = false
            store.onExternalChange = { [weak self] previous, current, preservedRequest in
                self?.applyExternalSnapshot(previous: previous, current: current, preservedRequest: preservedRequest)
            }
        } catch {
            catalogBlocked = true
            message = "配置或历史无法安全迁移／恢复，原文件与配置已保留；请检查备份及存储权限后重开。"
        }
        initialRequestAttempts.finishRegistration()
        browsingAirport = activeProfiles.first?.id
    }

    private func applyExternalSnapshot(previous: NativeSnapshot, current: NativeSnapshot, preservedRequest: UUID?) {
        let oldProfiles = previous.catalog.profiles
        publishing = true
        profiles = current.catalog.profiles
        menuAirport = current.catalog.menuAirport
        publishing = false
        for id in Array(monitors.keys) where !profiles.contains(where: { $0.id == id }) {
            monitors.removeValue(forKey: id)?.stop()
            observations.removeValue(forKey: id)?.cancel()
        }
        for profile in profiles {
            guard let source = current.sources.first(where: { $0.id == profile.historyID && $0.airportID == profile.id }) else { continue }
            guard let monitor = monitors[profile.id] else {
                attach(makeMonitor(profile, automatically: startAutomatically), to: profile.id)
                continue
            }
            let oldProfile = oldProfiles.first { $0.id == profile.id }
            let oldSource = oldProfile.flatMap { old in previous.sources.first { $0.id == old.historyID && $0.airportID == old.id } }
            let lifecycleChanged = oldProfile?.enabled != profile.enabled || oldProfile?.archived != profile.archived
            if oldSource?.revision != source.revision || oldSource?.id != source.id {
                let readChanged = oldSource?.effectiveReadContextRevision != source.effectiveReadContextRevision || lifecycleChanged
                monitor.applyStoredSource(source, invalidateRead: readChanged && preservedRequest != profile.id)
            }
            if lifecycleChanged {
                monitor.setLifecycle(enabled: profile.enabled, archived: profile.archived, refreshOnResume: false)
            }
            if previous.statisticsTimeZone != current.statisticsTimeZone { monitor.statisticsTimeZoneDidChange() }
        }
        if browsingAirport == nil || !activeProfiles.contains(where: { $0.id == browsingAirport }) {
            browsingAirport = activeProfiles.first?.id
        }
        objectWillChange.send()
    }

    private func makeMonitor(_ profile: AirportProfile, automatically: Bool) -> MonitorModel {
        let monitor = MonitorModel(profileID: profile.historyID, credentialAccount: profile.credentialAccount, defaults: defaults,
                     enabled: profile.enabled && !profile.archived, services: services, historyDirectory: historyDirectory,
                     startAutomatically: automatically, repository: repository, airportID: profile.id,
                     initialRequestAttempts: initialRequestAttempts)
        monitor.setLifecycle(enabled: profile.enabled, archived: profile.archived, refreshOnResume: false)
        return monitor
    }

    func sourceHistory(for profile: AirportProfile) -> [SourceRecord] { repository?.history(for: profile.id) ?? [] }
    func currentSource(for profile: AirportProfile) -> SourceRecord? { repository?.source(for: profile.id) }
    var statisticsTimeZoneIdentifier: String { repository?.snapshot.statisticsTimeZone ?? TimeZone.current.identifier }
    var systemNotificationsEnabled: Bool { defaults.bool(forKey: "remindersEnabled") }

    @discardableResult func setStatisticsTimeZone(_ identifier: String) -> Bool {
        guard !isDemo, let repository else { message = "演示模式不修改统计时区。"; return false }
        do {
            try repository.setStatisticsTimeZone(identifier)
            for monitor in monitors.values { monitor.statisticsTimeZoneDidChange() }
            objectWillChange.send(); message = "统计时区已更新，原始记录与重置规则保留。"
            return true
        } catch { message = "统计时区未能保存，请检查时区后重试。"; return false }
    }

    func makePreview() -> SubscriptionPreview {
        if isDemo {
            return SubscriptionPreview(fetch: { _ in
                try Subscription(upload: 0, download: 42_000_000_000, total: 200_000_000_000,
                                 expiry: Date().addingTimeInterval(30 * 86400))
            })
        }
        let attempts = initialRequestAttempts, fetch = services.fetch
        let check = services.nextSubscriptionRequest, now = services.now
        return SubscriptionPreview(fetch: { url in
            try await attempts.waitUntilReady()
            if let attempt = attempts.latest(for: try SubscriptionRequestGate.identity(for: url)) {
                let available = try await check(url, attempt)
                try Task.checkCancellation()
                if let available, available > now() { throw SubscriptionCooldown(until: available) }
            }
            return try await fetch(url)
        }, now: now)
    }

    func confirmPreview(_ preview: SubscriptionPreview, name: String, plan: String = "") async -> UUID? {
        let identity = ObjectIdentifier(preview)
        guard confirmingPreviews.insert(identity).inserted else { return nil }
        defer { confirmingPreviews.remove(identity) }
        guard let result = preview.confirmation else { message = "请先读取订阅信息。"; return nil }
        let saved = await save(profile: nil, name: name, plan: plan, subscription: result.url.absoluteString,
                               reset: ResetRule(), threshold: 10, initialReading: result)
        guard saved else { return nil }
        preview.cancel()
        return browsingAirport
    }

    private func attach(_ monitor: MonitorModel, to id: UUID) {
        monitors[id] = monitor
        observations[id] = monitor.objectWillChange.sink { [weak self, weak monitor] _ in
            Task { @MainActor in
                guard let self, let monitor else { return }
                if let index = self.profiles.firstIndex(where: { $0.id == id }), self.profiles[index].historyID != monitor.currentProfileID {
                    if let repository = self.repository { self.profiles = repository.snapshot.catalog.profiles }
                    else { self.profiles[index].historyID = monitor.currentProfileID; self.persist() }
                }
                self.objectWillChange.send()
            }
        }
    }

    func setAppearance(_ value: AppAppearance) {
        appearanceMode = value
        if !isDemo { defaults.set(value.rawValue, forKey: "appearanceMode.v1") }
        NSApp?.appearance = value.native
    }

    func setMenuPanelLayout(_ value: MenuPanelLayout) {
        menuPanelLayout = value
        panelExplanationOpen = false
        if !isDemo { defaults.set(value.rawValue, forKey: "menuPanelLayout.v1") }
    }

    var savedSettingsSection: SettingsSection? {
        defaults.string(forKey: "settings.selectedSection").flatMap(SettingsSection.init(rawValue:))
    }

    func rememberSettingsSection(_ section: SettingsSection) {
        if !isDemo { defaults.set(section.rawValue, forKey: "settings.selectedSection") }
    }

    private func persist() {
        guard !isDemo, !catalogBlocked, !publishing, let repository else { return }
        do {
            try repository.updateCatalog(AirportCatalog(version: 2, profiles: profiles, menuAirport: menuAirport))
        } catch {
            publishing = true; profiles = repository.snapshot.catalog.profiles; menuAirport = repository.snapshot.catalog.menuAirport
            for profile in profiles { monitors[profile.id]?.setLifecycle(enabled: profile.enabled, archived: profile.archived, refreshOnResume: false) }
            publishing = false
            message = "机场配置未能保存，原配置保持，请重试。"
        }
    }

    func save(profile: AirportProfile?, name: String, plan: String, subscription: String, reset: ResetRule, threshold: Double,
              change: SubscriptionChange = .sameSource, reminderPreferences: ReminderPreferences? = nil,
              airportRemindersEnabled: Bool? = nil, initialReading: SubscriptionPreview.Result? = nil) async -> Bool {
        guard !isDemo, !catalogBlocked else { message = isDemo ? "演示模式不保存订阅。" : "请先修复机场配置。"; return false }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, threshold.isFinite, threshold > 0, threshold <= 1_000_000 else {
            message = "填写机场名称，提醒阈值需大于 0 且不超过 1,000,000 GB。"; return false
        }
        do { try reset.validate(); if !subscription.isEmpty { _ = try Subscription.validatedURL(subscription) } }
        catch { message = error.localizedDescription; return false }
        guard let repository else { return false }
        let saveKey = profile?.id.uuidString ?? "new"
        guard saving.insert(saveKey).inserted else { return false }
        defer { saving.remove(saveKey) }
        do {
            let saved = try repository.saveAirport(profile: profile, name: name, plan: plan, subscription: subscription,
                                                   reset: reset, threshold: threshold, change: change,
                                                   reminderPreferences: reminderPreferences, airportRemindersEnabled: airportRemindersEnabled,
                                                   initialReading: initialReading)
            publishing = true; profiles = repository.snapshot.catalog.profiles; menuAirport = repository.snapshot.catalog.menuAirport; publishing = false
            let monitor: MonitorModel
            if let existing = monitors[saved.id] {
                monitor = existing; monitor.applyStoredSource(repository.source(for: saved.id)!)
            } else {
                monitor = makeMonitor(saved, automatically: false); attach(monitor, to: saved.id)
                if startAutomatically { monitor.startMonitoring() }
            }
            browsingAirport = saved.id
            message = repository.recoveryPending ? "机场已保存，清理将在下次恢复时重试。" : "机场已保存。"
            // Consume the preview before any suspension: repeated confirmation cannot create another airport.
            if initialReading == nil && !subscription.isEmpty { await monitor.refresh() }
            else if initialReading == nil { await monitor.evaluateReminders() }
            return true
        } catch {
            message = "保存失败，原配置和历史保持，请修改后重试。"
            return false
        }
    }

    func setEnabled(_ profile: AirportProfile, _ enabled: Bool) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }),
              !profiles[index].archived, profiles[index].enabled != enabled else { return }
        var candidate = profiles
        candidate[index].enabled = enabled
        _ = commitLifecycle(candidate, primary: menuAirport)
    }
    @discardableResult
    func archive(_ profile: AirportProfile, archived: Bool) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return false }
        guard profiles[index].archived != archived else { return true }
        var candidate = profiles
        candidate[index].archived = archived
        let active = candidate.filter { !$0.archived }
        let primary = active.contains(where: { $0.id == menuAirport }) ? menuAirport :
            (active.first(where: { $0.enabled }) ?? active.first)?.id
        guard commitLifecycle(candidate, primary: primary) else { return false }
        if browsingAirport == profile.id && archived { browsingAirport = active.first?.id }
        if browsingAirport == nil { browsingAirport = active.first?.id }
        return true
    }

    /// Commit before publishing or cancelling: a failed disk write must leave the
    /// current request and the visible lifecycle untouched.
    private func commitLifecycle(_ candidate: [AirportProfile], primary: UUID?) -> Bool {
        guard !catalogBlocked else { return false }
        do {
            if !isDemo {
                guard let repository else { return false }
                try repository.updateCatalog(AirportCatalog(version: 2, profiles: candidate, menuAirport: primary))
            }
            let previous = profiles
            publishing = true; profiles = candidate; menuAirport = primary; publishing = false
            for profile in candidate {
                guard let old = previous.first(where: { $0.id == profile.id }),
                      old.enabled != profile.enabled || old.archived != profile.archived else { continue }
                monitors[profile.id]?.setLifecycle(enabled: profile.enabled, archived: profile.archived)
            }
            message = nil
            return true
        } catch {
            message = "机场配置未能保存，原配置保持，请重试。"
            return false
        }
    }
    func setInterval(_ minutes: Int) {
        let safe = SubscriptionRefreshPolicy.normalized(minutes)
        if !isDemo { defaults.set(safe, forKey: "intervalMinutes") }
        for monitor in monitors.values { monitor.applyInterval(safe) }
        objectWillChange.send()
    }
    func setReminders(_ enabled: Bool) async {
        guard !isDemo else { return }
        defaults.set(enabled, forKey: "remindersEnabled")
        for monitor in monitors.values { monitor.remindersEnabled = enabled }
        notificationPermissionError = nil
        // Permission belongs to the workspace, including an empty one.
        if enabled, await services.notificationAuthorizationStatus() == .notDetermined {
            do { _ = try await services.requestNotificationAuthorization() }
            catch { notificationPermissionError = "无法申请通知权限，请检查系统通知设置。" }
        }
        await refreshNotificationAuthorization()
        for monitor in monitors.values { await monitor.evaluateReminders() }
        objectWillChange.send()
    }

    func refreshNotificationAuthorization() async {
        guard !isDemo else { notificationAuthorizationStatus = "演示模式不申请或发送系统通知"; return }
        switch await services.notificationAuthorizationStatus() {
        case .authorized, .provisional: notificationAuthorizationStatus = "系统已允许通知"
        case .denied: notificationAuthorizationStatus = "系统通知未允许，请在系统设置中开启"
        case .notDetermined: notificationAuthorizationStatus = "开启后将申请系统通知权限"
        default: notificationAuthorizationStatus = "通知权限状态未知"
        }
        for monitor in monitors.values { await monitor.updateNotificationStatus() }
    }
    func setDisplay(unit: TrafficUnit? = nil, menu: MenuDisplay? = nil) {
        for monitor in monitors.values {
            if let unit { monitor.trafficUnit = unit }
            if let menu { monitor.menuDisplay = menu }
        }
        if !isDemo {
            if let unit { defaults.set(unit.rawValue, forKey: "trafficUnit") }
            if let menu { defaults.set(menu.rawValue, forKey: "menuDisplay") }
        }
        objectWillChange.send()
    }
    func refreshAll() async {
        let ids = activeProfiles.map(\.id)
        for id in ids {
            guard let profile = profiles.first(where: { $0.id == id }), profile.enabled, !profile.archived else { continue }
            await model(for: profile).refresh(purpose: .automatic)
        }
    }

    private func makeDemo() {
        for (index, name) in ["云海", "松林", "北屿"].enumerated() {
            let total: Double = index == 0 ? 214.75 : index == 1 ? 100 : 200
            let left: Double = [191.2, 8, 12.6][index], daily: Double = [1.83, 0.2, 4.1][index]
            var ledger = Ledger()
            let now = Date(), start = Calendar.current.startOfDay(for: now).addingTimeInterval(-8 * 86400)
            let count = Int(now.timeIntervalSince(start) / 300)
            for i in 0...count {
                let date = start.addingTimeInterval(Double(i) * 300)
                let used = max(0, total - left - daily * now.timeIntervalSince(date) / 86400)
                if let subscription = try? Subscription(upload: 0, download: UInt64(used * 1e9), total: UInt64(total * 1e9), expiry: now.addingTimeInterval(100 * 86400)) {
                    _ = try? ledger.append(subscription, at: date)
                }
            }
            let id = UUID(), history = UUID().uuidString
            if CommandLine.arguments.contains("--collecting-preview"), index == 1, let sample = ledger.samples.last {
                ledger = Ledger(); _ = try? ledger.append(sample.subscription, at: sample.date)
            }
            if CommandLine.arguments.contains("--edge-preview") {
                ledger = Ledger()
                if index == 1, let subscription = try? Subscription(upload: 0, download: 5_000_000_000, total: 0) { _ = try? ledger.append(subscription) }
                if index == 2, let subscription = try? Subscription(upload: 0, download: 200_000_000_000, total: 200_000_000_000, expiry: Date().addingTimeInterval(-86400)) { _ = try? ledger.append(subscription) }
            }
            let p = AirportProfile(id: id, historyID: history, credentialAccount: "demo-\(index)", name: name,
                                   plan: ["年付 · 200 GB", "月付 · 100 GB", "季付 · 200 GB"][index], enabled: true, archived: false)
            let monitor = MonitorModel(profileID: history, defaults: defaults, demoLedger: ledger)
            monitor.configureDemo(error: index == 2 ? "订阅服务器暂时不可达" : nil)
            profiles.append(p); attach(monitor, to: id)
        }
        if CommandLine.arguments.contains("--edge-preview"), !profiles.isEmpty { profiles[0].name = "云海 · 用于检查超长机场名称与套餐信息的独立设计预览" }
        menuAirport = profiles.first?.id; browsingAirport = profiles.first?.id
    }
}
