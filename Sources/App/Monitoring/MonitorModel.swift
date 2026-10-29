import AppKit
import SwiftUI
import UserNotifications
#if SWIFT_PACKAGE
import TrafficCore
typealias Subscription = TrafficCore.Subscription
#endif

struct DailyUsage: Identifiable {
    let date: Date
    let summary: UsageSummary
    var coverage: Double = 0
    var hasUnallocated = false
    var hasExcluded = false
    var hasKnownUsage: Bool { summary.intervals > 0 }
    var id: Date { date }
}

@MainActor
struct MonitorServices {
    var readCredential: (String) throws -> String? = { try Keychain.read(account: $0) }
    var saveCredential: (String, String) throws -> Void = { try Keychain.save($0, account: $1) }
    var deleteCredential: (String) throws -> Void = { try Keychain.delete(account: $0) }
    var fetch: (URL) async throws -> Subscription = { try await SubscriptionClient().fetch($0) }
    var notificationAuthorizationStatus: () async -> UNAuthorizationStatus = {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
    var requestNotificationAuthorization: () async throws -> Bool = {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    var now: () -> Date = Date.init
    var reminderServices: ReminderServices?
    var waitForReadStoreRetry: () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) }
    // Injected test transports remain isolated. Production uses the same durable
    // gate as SubscriptionClient, seeded from pre-upgrade observations.
    var nextSubscriptionRequest: (URL, Date?) throws -> Date? = { _, _ in nil }
    static func live() -> MonitorServices {
        var services = MonitorServices()
        services.nextSubscriptionRequest = { try SubscriptionRequestGate.shared.nextAllowedDate(for: $0, observedAttempt: $1) }
        return services
    }
}

enum SyncPurpose { case automatic, manual }

@MainActor
final class MonitorModel: ObservableObject {
    @Published private(set) var ledger = Ledger() {
        didSet { dayRecords.removeAll(); observationAnalyses.removeAll() }
    }
    @Published private(set) var busy = false
    @Published private(set) var hasURL = false
    @Published private(set) var error: String?
    @Published private(set) var requestAvailableAt: Date?
    var requestWaitingMessage: String? {
        guard let date = requestAvailableAt, date > services.now() else { return nil }
        return SubscriptionCooldown(until: date).localizedDescription
    }
    @Published private(set) var storageBlocked = false
    @Published private(set) var notificationStatus = "尚未申请权限"
    @Published private(set) var reminderDeliveryStatus: ReminderDeliveryStatus = .idle
    @Published private(set) var nextRefresh: Date?
    @Published var intervalMinutes: Int { didSet { dayRecords.removeAll() } }
    @Published var remindersEnabled: Bool {
        didSet {
            if oldValue && !remindersEnabled {
                pendingReminderReset = true
                _ = resetReminderConfirmationsIfNeeded()
            }
        }
    }
    @Published var thresholdGB: Double
    @Published var settingsMessage: String?
    @Published private(set) var resetRule = ResetRule() {
        didSet { dayRecords.removeAll(); observationAnalyses.removeAll() }
    }
    @Published var trafficUnit: TrafficUnit {
        didSet { if !isDemo { defaults.set(trafficUnit.rawValue, forKey: "trafficUnit") } }
    }
    @Published var menuDisplay: MenuDisplay {
        didSet { if !isDemo { defaults.set(menuDisplay.rawValue, forKey: "menuDisplay") } }
    }

    @Published private(set) var profileID: String
    @Published private(set) var syncAttempts: [SyncAttempt] = []
    @Published var enabled = true
    let isDemo: Bool
    private let credentialAccount: String
    private let services: MonitorServices
    private let historyDirectory: URL?
    private let repository: NativeRepository?
    private let airportID: UUID?
    @Published private(set) var linkVerificationPending = false
    @Published private(set) var syncPending = false
    private(set) var archived = false
    private var readLifecycle = SubscriptionReadLifecycle()
    private var preparingRead: UUID?
    private var monitoringStarted = false
    private var syncLogBlocked = false
    private var dayRecords: [DateInterval: DailyUsage] = [:]
    private var dayRecordRevisions: [StatisticsRuleRevision]?
    private var observationAnalyses: [(rule: ResetRule, revisions: [StatisticsRuleRevision], value: ObservationAnalysis)] = []
    private var timer: Task<Void, Never>?
    private var reminderRetryTask: Task<Void, Never>?
    private var pendingReminderReset = false
    private var wakeObserver: NSObjectProtocol?
    private let defaults: UserDefaults
    private let fallbackStatisticsTimeZone = TimeZone.current
    private var historyStore: HistoryStore {
        let root = historyDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SurgeTrafficMonitor")
        return HistoryStore(url: root.appendingPathComponent("\(profileID).json"))
    }
    var latest: Sample? { ledger.samples.last }
    var currentProfileID: String { profileID }
    private var resetKey: String { "resetRule.\(profileID)" }
    var referenceDate: Date { isDemo ? latest?.date ?? services.now() : services.now() }
    var nextReset: Date? { resetRule.window(at: referenceDate).next }
    private var storedSource: SourceRecord? { airportID.flatMap { repository?.source(for: $0) } }
    var ruleRevisions: [StatisticsRuleRevision] {
        storedSource?.resetRevisions.map { StatisticsRuleRevision(effectiveAt: $0.effectiveAt, rule: $0.rule) } ?? []
    }
    private func observationAnalysis(rule: ResetRule, revisions: [StatisticsRuleRevision]) -> ObservationAnalysis {
        if let cached = observationAnalyses.first(where: { $0.rule == rule && $0.revisions == revisions }) {
            return cached.value
        }
        let value = ObservationAnalysis(ledger: ledger, rule: rule, revisions: revisions)
        // The current and last-reading rules can differ after an edit. Keep the
        // cache bounded while allowing both views to reuse their interpretation.
        if observationAnalyses.count == 2 { observationAnalyses.removeFirst() }
        observationAnalyses.append((rule, revisions, value))
        return value
    }
    private var currentObservationAnalysis: ObservationAnalysis {
        let revisions = ruleRevisions
        if dayRecordRevisions != revisions {
            dayRecords.removeAll()
            dayRecordRevisions = revisions
        }
        return observationAnalysis(rule: resetRule, revisions: revisions)
    }
    var statisticsIntervals: [UsageInterval] { currentObservationAnalysis.intervals }
    func statistics(in period: DateInterval) -> UsageReport {
        guard period.duration > 0 else { return ledger.usageReport(in: period, calendar: calendar) }
        return currentObservationAnalysis.usageReport(in: period, calendar: calendar)
    }
    private var forecastAvailability: ForecastAvailability {
        ForecastAvailability(paused: !enabled || archived, synchronizing: busy,
                             pendingVerification: syncPending || linkVerificationPending,
                             // The first revision establishes the source's rule; only later revisions change it.
                             resetRuleChanged: ruleRevisions.dropFirst().contains {
                                 guard let date = $0.effectiveAt, let latest else { return false }
                                 return date >= latest.date && date <= referenceDate
                             })
    }
    var balanceTrend: BalanceTrend {
        currentObservationAnalysis.balanceTrend(at: referenceDate, intervalMinutes: intervalMinutes,
                                                calendar: calendar, synchronizationFailed: error != nil || storageBlocked,
                                                availability: forecastAvailability)
    }
    var calendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = repository.flatMap { TimeZone(identifier: $0.snapshot.statisticsTimeZone) } ?? fallbackStatisticsTimeZone
        return calendar
    }
    func statisticsTimeZoneDidChange() {
        dayRecords.removeAll()
        objectWillChange.send()
    }
    var today: UsageSummary { statistics(in: calendar.dateInterval(of: .day, for: referenceDate)!).summary }
    var week: UsageSummary { statistics(in: calendar.dateInterval(of: .weekOfYear, for: referenceDate)!).summary }
    var stale: Bool {
        !isDemo && (latest.map { referenceDate < $0.date || referenceDate.timeIntervalSince($0.date) > SubscriptionRefreshPolicy.freshnessInterval(minutes: intervalMinutes) } ?? false)
    }
    var recentDays: [DailyUsage] {
        (0..<7).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: referenceDate),
                  let period = calendar.dateInterval(of: .day, for: date) else { return nil }
            return dayRecord(period)
        }
    }
    var menuTitle: String {
        guard let latest else { return "流量 —" }
        return latest.subscription.remaining.map { trafficUnit.menuText($0) } ?? "余量未知"
    }
    var lowBalance: Bool {
        latest?.subscription.remaining.map { Double($0) / 1e9 <= thresholdGB } ?? false
    }
    var forecastResult: ForecastResult {
        currentObservationAnalysis.forecast(at: referenceDate, intervalMinutes: intervalMinutes, calendar: calendar,
                                            synchronizationFailed: error != nil || storageBlocked,
                                            availability: forecastAvailability)
    }
    /// Display-only snapshot: always evaluate at the last real observation, so
    /// timers, failures and restarts cannot slide the estimate into the present.
    /// Existing forecastResult remains the input for all reminder decisions.
    var samplingForecastResult: ForecastResult {
        guard let latest else {
            return observationAnalysis(rule: resetRule, revisions: [])
                .forecast(at: referenceDate, intervalMinutes: intervalMinutes, calendar: calendar, mode: .samplingSnapshot)
        }
        let allRevisions = ruleRevisions
        let revisions = allRevisions.filter { $0.effectiveAt.map { $0 < latest.date } ?? true }
        let rule = revisions.last?.rule ?? (allRevisions.isEmpty ? resetRule : ResetRule())
        return observationAnalysis(rule: rule, revisions: revisions)
            .forecast(at: latest.date, intervalMinutes: intervalMinutes, calendar: calendar, mode: .samplingSnapshot)
    }
    var samplingForecastIsHistorical: Bool {
        let result = samplingForecastResult
        return error != nil || storageBlocked || busy || !enabled || archived ||
            syncPending || linkVerificationPending || forecastAvailability.resetRuleChanged ||
            latest.map { $0.date > referenceDate } == true || expired ||
            result.estimate?.boundary.map { $0 <= referenceDate } == true
    }
    /// A timestamped estimate from the last successful observation. Never used for current risk or notifications.
    var historicalForecastResult: ForecastResult? {
        guard let latest else { return nil }
        let allRevisions = ruleRevisions
        let revisions = allRevisions.filter { $0.effectiveAt.map { $0 < latest.date } ?? true }
        let historicalRule = revisions.last?.rule ?? (allRevisions.isEmpty ? resetRule : ResetRule())
        let result = observationAnalysis(rule: historicalRule, revisions: revisions)
            .forecast(at: latest.date, intervalMinutes: intervalMinutes, calendar: calendar)
        return result.estimate == nil ? nil : result
    }
    var expired: Bool { latest?.subscription.expiry.map { $0 <= referenceDate } ?? false }
    func usageText(_ summary: UsageSummary) -> String {
        summary.intervals == 0 ? "等待采样" : "≥ \(trafficUnit.value(summary.bytes)) \(trafficUnit.label)"
    }

    init(profileID: String? = nil, credentialAccount: String = "active-url", defaults: UserDefaults = .standard,
         demoLedger: Ledger? = nil, enabled: Bool = true, services: MonitorServices? = nil,
         historyDirectory: URL? = nil, startAutomatically: Bool = true,
         repository: NativeRepository? = nil, airportID: UUID? = nil) {
        self.defaults = defaults; self.credentialAccount = credentialAccount; self.isDemo = demoLedger != nil
        self.services = services ?? MonitorServices.live(); self.historyDirectory = historyDirectory
        self.repository = repository; self.airportID = airportID
        self.enabled = enabled
        trafficUnit = TrafficUnit(rawValue: defaults.string(forKey: "trafficUnit") ?? "") ?? .gb
        menuDisplay = MenuDisplay(rawValue: defaults.string(forKey: "menuDisplay") ?? "") ?? .iconAndBalance
        let savedID = repository.flatMap { store in airportID.flatMap { store.source(for: $0)?.id } } ?? defaults.string(forKey: "historyProfile.\(credentialAccount)") ?? profileID ?? defaults.string(forKey: "profileID") ?? UUID().uuidString
        self.profileID = savedID
        if profileID == nil && demoLedger == nil && repository == nil { defaults.set(savedID, forKey: "profileID") }
        let minutes = defaults.integer(forKey: "intervalMinutes")
        intervalMinutes = SubscriptionRefreshPolicy.normalized(minutes)
        remindersEnabled = defaults.bool(forKey: "remindersEnabled")
        let threshold = defaults.object(forKey: "thresholdGB.\(credentialAccount)") as? Double ?? defaults.double(forKey: "thresholdGB")
        thresholdGB = threshold.isFinite && threshold > 0 ? threshold : 10
        loadResetRule()
        if let demoLedger {
            ledger = demoLedger; hasURL = true
            var rule = ResetRule(); rule.kind = .monthly
            rule.day = calendar.component(.day, from: calendar.date(byAdding: .day, value: 7, to: Date())!)
            resetRule = rule
            return
        }
        if let repository, let airportID, let source = repository.source(for: airportID) {
            applyStoredSource(source)
        } else {
            do { hasURL = try self.services.readCredential(credentialAccount) != nil } catch { self.error = error.localizedDescription }
            loadHistory()
            do { syncAttempts = try SyncAttemptStore(url: historyStore.url.appendingPathExtension("sync")).load() }
            catch { syncLogBlocked = true; settingsMessage = "同步记录无法读取，原文件已保留。" }
        }
        do {
            let reference = airportID.flatMap { repository?.source(for: $0)?.credentialReference } ?? credentialAccount
            if let secret = try self.services.readCredential(reference) {
                let attempt = (syncAttempts.map(\.date) + [latest?.date].compactMap { $0 }).max()
                requestAvailableAt = try self.services.nextSubscriptionRequest(Subscription.validatedURL(secret), attempt)
            }
        } catch {
            storageBlocked = true
            self.error = "无法确认订阅请求间隔，已停止请求以避免过于频繁。请检查本地存储。"
        }
        guard startAutomatically else { return }
        startMonitoring()
        let initialGeneration = readLifecycle.generation
        Task { [weak self] in
            guard let self else { return }
            await updateNotificationStatus()
            guard readLifecycle.generation == initialGeneration else { return }
            await refresh(purpose: .automatic)
        }
    }

    func startMonitoring() {
        guard !isDemo, wakeObserver == nil else { return }
        monitoringStarted = true
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in await self?.refresh(purpose: .automatic) } }
        schedule()
    }

    private func loadHistory() {
        do { ledger = try historyStore.load(); storageBlocked = false }
        catch { storageBlocked = true; self.error = "历史文件无法读取，已停止采样以保护原文件。可在设置中隔离文件并重新开始。" }
    }

    private func loadResetRule() {
        resetRule = ResetRule()
        guard let data = defaults.data(forKey: resetKey) else { return }
        do {
            let rule = try JSONDecoder().decode(ResetRule.self, from: data)
            try rule.validate(); resetRule = rule
        } catch { settingsMessage = "重置设置无法读取，请重新配置；原历史已保留。" }
    }

    /// Invalidates both successful and failed completions, even if a transport ignores cancellation.
    func invalidateRequests() {
        readLifecycle.invalidate()
        preparingRead = nil
        busy = false
    }

    func setLifecycle(enabled: Bool, archived: Bool, refreshOnResume: Bool = true) {
        let changed = self.enabled != enabled || self.archived != archived
        guard changed else { return }
        invalidateRequests()
        reminderRetryTask?.cancel(); reminderRetryTask = nil
        self.enabled = enabled; self.archived = archived
        if let airportID, let source = repository?.source(for: airportID) {
            linkVerificationPending = source.needsVerification
        }
        syncPending = true
        schedule()
        let resumedGeneration = readLifecycle.generation
        Task { [weak self] in
            guard let self, readLifecycle.generation == resumedGeneration else { return }
            await evaluateReminders()
            if readLifecycle.generation == resumedGeneration, enabled && !archived && refreshOnResume {
                await refresh(purpose: .automatic)
            }
        }
    }

    private func canFetch(_ purpose: SyncPurpose) -> Bool {
        guard !archived, purpose == .manual || enabled else { return false }
        if let repository, let airportID {
            guard let profile = repository.snapshot.catalog.profiles.first(where: { $0.id == airportID }),
                  !profile.archived, purpose == .manual || profile.enabled else { return false }
        }
        return true
    }

    func refresh(purpose: SyncPurpose = .manual) async {
        guard !Task.isCancelled, !busy, preparingRead == nil, !storageBlocked, !isDemo else { return }
        let preparation = UUID()
        preparingRead = preparation
        defer { if preparingRead == preparation { preparingRead = nil } }
        let preparingGeneration = readLifecycle.generation
        if let repository {
            while true {
                do { try repository.synchronize(); break }
                catch RepositoryConflict.busy {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard !Task.isCancelled, preparingRead == preparation,
                          readLifecycle.generation == preparingGeneration else { return }
                }
                catch { settingsMessage = "本地数据暂时无法同步，请稍后重试。"; return }
            }
        }
        guard !Task.isCancelled, canFetch(purpose) else { return }
        let source = airportID.flatMap { repository?.source(for: $0) }
        let sourceID = profileID, credential = source?.credentialReference ?? credentialAccount
        let context: ObservationContext? = {
            guard let airportID, let source, let repository,
                  let profile = repository.snapshot.catalog.profiles.first(where: { $0.id == airportID }) else { return nil }
            return ObservationContext(airportID: airportID, sourceID: source.id,
                credentialReference: source.credentialReference, readRevision: source.effectiveReadContextRevision,
                externalReadGeneration: repository.externalReadGeneration(for: airportID),
                enabled: profile.enabled, archived: profile.archived)
        }()
        if repository != nil && context == nil { return }
        guard let token = readLifecycle.begin() else { return }
        if preparingRead == preparation { preparingRead = nil }
        func eligible() -> Bool {
            guard readLifecycle.isActive(token),
                  profileID == sourceID, canFetch(purpose) else { return false }
            if let repository, let airportID {
                guard let current = repository.source(for: airportID), current.id == sourceID,
                      current.credentialReference == credential else { return false }
            }
            return true
        }
        func store(_ outcome: SubscriptionReadOutcome, at date: Date) async throws -> SourceRecord? {
            guard let repository, let context else { return nil }
            while true {
                do { return try repository.recordRead(outcome, at: date, context: context) }
                catch RepositoryConflict.busy {
                    // Keep the completed result while another process publishes;
                    // cancellation or a context change still stops the retry.
                    try await services.waitForReadStoreRetry()
                    guard eligible(), !Task.isCancelled, !readLifecycle.taskIsCancelled(token) else { throw CancellationError() }
                }
            }
        }
        busy = true
        defer {
            if readLifecycle.finish(token) { busy = false }
        }
        do {
            guard let secret = try services.readCredential(credential) else { hasURL = false; return }
            hasURL = true
            let url = try Subscription.validatedURL(secret)
            let lastAttempt = (syncAttempts.map(\.date) + [latest?.date].compactMap { $0 }).max()
            requestAvailableAt = try services.nextSubscriptionRequest(url, lastAttempt)
            if let date = requestAvailableAt, date > services.now() { throw SubscriptionCooldown(until: date) }
            let request = Task { try await services.fetch(url) }
            guard readLifecycle.attach(request, to: token) else { return }
            let result = try await withTaskCancellationHandler(operation: { try await request.value }, onCancel: { request.cancel() })
            guard eligible(), !Task.isCancelled, !request.isCancelled else { return }
            let observedAt = services.now()
            let updated: Ledger
            do {
                if repository != nil {
                    guard let source = try await store(.success(result), at: observedAt) else { return }
                    updated = source.ledger
                    syncAttempts = source.syncAttempts; linkVerificationPending = false
                } else {
                    var legacy = ledger
                    try legacy.append(result, at: observedAt)
                    try historyStore.save(legacy)
                    updated = legacy
                }
            } catch { throw TrafficError.storage }
            ledger = updated
            error = nil; syncPending = false
            if repository == nil { recordSync(subscription: result, message: nil) }
            if readLifecycle.finish(token) { busy = false }
            await evaluateReminders()
        } catch let cooldown as SubscriptionCooldown {
            guard eligible(), !Task.isCancelled else { return }
            requestAvailableAt = cooldown.until
            settingsMessage = cooldown.localizedDescription
            // A local throttle is not a failed network attempt and must not
            // extend the cooldown or replace the last real synchronization error.
            if enabled && !archived { nextRefresh = cooldown.until }
        } catch {
            guard eligible(), !Task.isCancelled, !readLifecycle.taskIsCancelled(token),
                  !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            let message = error.localizedDescription
            if repository != nil {
                do {
                    guard let source = try await store(.failure(message), at: services.now()) else { return }
                    syncAttempts = source.syncAttempts
                } catch is CancellationError { return }
                catch { settingsMessage = "同步记录未能保存，原记录保留。" }
            } else { recordSync(subscription: nil, message: message) }
            guard eligible(), !Task.isCancelled else { return }
            self.error = message
            if readLifecycle.finish(token) { busy = false }
            await evaluateReminders()
        }
    }

    func saveSubscription(_ text: String, change: SubscriptionChange = .sameSource) async -> Bool {
        guard !busy, !isDemo else { return false }
        do {
            if let repository, let airportID,
               let profile = repository.snapshot.catalog.profiles.first(where: { $0.id == airportID }) {
                _ = try repository.saveAirport(profile: profile, name: profile.name, plan: profile.plan, subscription: text,
                                               reset: resetRule, threshold: thresholdGB, change: change)
                applyStoredSource(repository.source(for: airportID)!)
                settingsMessage = "订阅已保存到本机钥匙串。"
                await refresh(); return true
            }
            let url = try Subscription.validatedURL(text)
            try services.saveCredential(url.absoluteString, credentialAccount)
            invalidateRequests()
            if change == .newSource {
                // Old ledgers remain on disk; unrelated subscriptions must never share counters.
                profileID = UUID().uuidString
                if credentialAccount == "active-url" { defaults.set(profileID, forKey: "profileID") }
                defaults.set(profileID, forKey: "historyProfile.\(credentialAccount)")
                ledger = Ledger(); storageBlocked = false
                syncAttempts = []; syncLogBlocked = false
                loadResetRule()
            }
            hasURL = true; error = nil
            settingsMessage = "订阅已保存到本机钥匙串。"
            await refresh()
            return true
        } catch { settingsMessage = error.localizedDescription; return false }
    }

    func removeSubscription() {
        guard !isDemo else { return }
        guard repository == nil else { settingsMessage = "请通过归档保留订阅与历史。"; return }
        do {
            try services.deleteCredential(credentialAccount)
            invalidateRequests()
            profileID = UUID().uuidString
            if credentialAccount == "active-url" { defaults.set(profileID, forKey: "profileID") }
            defaults.set(profileID, forKey: "historyProfile.\(credentialAccount)")
            ledger = Ledger(); hasURL = false; error = nil; storageBlocked = false
            syncAttempts = []; syncLogBlocked = false
            loadResetRule()
            settingsMessage = "订阅已移除，旧历史仍保存在本机。"
        } catch { settingsMessage = error.localizedDescription }
    }

    func recoverHistory() async {
        guard !busy, !isDemo else { return }
        guard repository == nil else { settingsMessage = "新版历史受保护，请恢复备份，不会清空旧记录。"; return }
        do {
            try historyStore.quarantine()
            ledger = Ledger(); storageBlocked = false; error = nil
            await refresh()
        } catch { settingsMessage = "无法隔离文件，请检查文件权限。" }
    }

    func savePreferences(interval: Int, reminders: Bool, threshold: Double, reset: ResetRule) async {
        guard !isDemo else { return }
        guard threshold.isFinite, threshold > 0, threshold <= 1_000_000 else {
            settingsMessage = "提醒阈值需大于 0 且不超过 1,000,000 GB。"; return
        }
        let resetData: Data
        do { try reset.validate(); resetData = try JSONEncoder().encode(reset) }
        catch { settingsMessage = TrafficError.invalidReset.localizedDescription; return }
        if let repository, let airportID, var source = repository.source(for: airportID) {
            if source.threshold != threshold { source.thresholdMode = .legacyAbsoluteGB }
            if source.threshold != threshold, var preferences = source.reminderPreferences {
                // This legacy settings entry still labels its input in GB.
                preferences.thresholdMode = .legacyAbsoluteGB
                preferences.lowThreshold = threshold; source.reminderPreferences = preferences
            }
            source.threshold = threshold
            if source.resetRule != reset {
                source.resetRevisions.append(ResetRevision(effectiveAt: services.now(), rule: reset))
                source.needsVerification = true
                source.clearReminderConfirmations()
            }
            do { try repository.updateSource(source) }
            catch { settingsMessage = "设置未能保存，原配置保持。"; return }
            linkVerificationPending = source.needsVerification
            syncPending = source.needsVerification
        }
        intervalMinutes = SubscriptionRefreshPolicy.normalized(interval)
        remindersEnabled = reminders
        thresholdGB = threshold
        defaults.set(intervalMinutes, forKey: "intervalMinutes")
        defaults.set(remindersEnabled, forKey: "remindersEnabled")
        if repository == nil {
            defaults.set(thresholdGB, forKey: "thresholdGB.\(credentialAccount)")
            defaults.set(resetData, forKey: resetKey)
        }
        resetRule = reset
        schedule()
        if remindersEnabled {
            do { _ = try await services.requestNotificationAuthorization() }
            catch { settingsMessage = "无法申请通知权限，请检查系统通知设置。"; return }
        }
        await updateNotificationStatus()
        settingsMessage = "设置已保存。"
        await evaluateReminders()
    }

    func updateNotificationStatus() async {
        guard !isDemo else { return }
        let status = await services.notificationAuthorizationStatus()
        switch status {
        case .authorized, .provisional, .ephemeral: notificationStatus = "已允许通知"
        case .denied: notificationStatus = "通知已被系统关闭，请到系统设置 → 通知中允许"
        case .notDetermined: notificationStatus = "尚未申请权限"
        @unknown default: notificationStatus = "通知权限状态未知"
        }
    }

    /// Global choices do not rewrite a source or depend on whether it is currently fetching.
    func applyGlobalPreferences(interval: Int? = nil, reminders: Bool? = nil) async {
        guard !isDemo else { return }
        if let interval { applyInterval(interval) }
        if let reminders {
            remindersEnabled = reminders
            defaults.set(reminders, forKey: "remindersEnabled")
            if reminders {
                do { _ = try await services.requestNotificationAuthorization() }
                catch { settingsMessage = "无法申请通知权限，请检查系统通知设置。" }
            }
            await updateNotificationStatus()
            await evaluateReminders()
        }
    }

    func evaluateReminders() async {
        guard !isDemo, !storageBlocked, let repository, let airportID else { return }
        let generation = readLifecycle.generation
        while true {
            do { try repository.synchronize(); break }
            catch RepositoryConflict.busy {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard !Task.isCancelled, readLifecycle.generation == generation else { return }
            }
            catch { reminderDeliveryStatus = .storageFailure; return }
        }
        guard resetReminderConfirmationsIfNeeded() else { reminderDeliveryStatus = .storageFailure; return }
        var delivery = services.reminderServices ?? ReminderServices()
        if services.reminderServices == nil {
            delivery.authorizationStatus = services.notificationAuthorizationStatus
            delivery.now = services.now
        }
        let expectedSource = profileID
        let result = await ReminderCoordinator(repository: repository, services: delivery)
            .evaluate(airportID: airportID) { [weak self] in
                guard let self, profileID == expectedSource, !storageBlocked,
                      let source = storedSource, source.id == expectedSource else { return nil }
                let fresh = error == nil && !stale && !busy && !syncPending && !linkVerificationPending
                let estimate = forecastResult.estimate
                let required = estimate.flatMap { estimate in
                    estimate.boundary.map { estimate.dailyBytes * max(0, $0.timeIntervalSince(self.latest?.date ?? self.referenceDate)) / 86_400 }
                }
                return ReminderInput(now: referenceDate, sampleID: latest?.id, observedAt: latest?.date,
                    remainingBytes: latest?.subscription.remaining.map { Double($0) },
                    totalBytes: latest.map { Double($0.subscription.total) }, expiry: latest?.subscription.expiry,
                    forecastRequiredBytes: required, usageFresh: fresh, forecastEligible: estimate != nil,
                    globalEnabled: remindersEnabled, airportEnabled: source.airportRemindersEnabled ?? true,
                    paused: !enabled, archived: archived)
            }
        guard profileID == expectedSource else { return }
        reminderDeliveryStatus = result
        reminderRetryTask?.cancel(); reminderRetryTask = nil
        if result == .retryScheduled, monitoringStarted, enabled, !archived,
           remindersEnabled, let retryAt = storedSource?.reminderDelivery?.retryAfter {
            let delay = max(1, retryAt.timeIntervalSince(services.now()))
            reminderRetryTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(min(delay, 86_400) * 1e9)) }
                catch { return }
                guard let self, !Task.isCancelled, profileID == expectedSource else { return }
                await evaluateReminders()
            }
        }
    }

    @discardableResult
    func saveReminderPreferences(_ preferences: ReminderPreferences, enabled: Bool) async -> Bool {
        guard !isDemo, let repository, let airportID, var source = repository.source(for: airportID) else { return false }
        guard preferences.isValid else {
            settingsMessage = "低余量阈值需为 1–50%，到期提前天数需为 2–30 天。"; return false
        }
        if source.reminderPreferences != preferences || (source.airportRemindersEnabled ?? true) != enabled {
            source.clearReminderConfirmations()
        }
        source.reminderPreferences = preferences
        source.airportRemindersEnabled = enabled
        do { try repository.updateSource(source) }
        catch { settingsMessage = "提醒设置未能保存，原配置保持。"; return false }
        settingsMessage = "提醒设置已保存。"
        await evaluateReminders()
        return true
    }

    private func resetReminderConfirmationsIfNeeded() -> Bool {
        guard pendingReminderReset else { return true }
        guard !isDemo, let repository, let airportID, var source = repository.source(for: airportID) else { return true }
        let prior = source.reminderState
        source.clearReminderConfirmations()
        if prior != source.reminderState {
            do { try repository.updateSource(source) }
            catch { return false }
        }
        pendingReminderReset = false
        return true
    }

    private func schedule() {
        timer?.cancel()
        timer = nil; nextRefresh = nil
        guard monitoringStarted, enabled, !archived, !isDemo else { return }
        let interval = Double(intervalMinutes) * 60
        let lastAttempt = (syncAttempts.map(\.date) + [latest?.date].compactMap { $0 }).max()
        nextRefresh = max(services.now(), lastAttempt?.addingTimeInterval(interval) ?? services.now().addingTimeInterval(interval))
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let now = self?.services.now() else { return }
                let wait = max(1, (self?.nextRefresh ?? now.addingTimeInterval(interval)).timeIntervalSince(now))
                do { try await Task.sleep(for: .seconds(wait)) }
                catch { return }
                guard !Task.isCancelled else { return }
                await self?.refresh(purpose: .automatic)
                if let self {
                    nextRefresh = max(requestAvailableAt ?? .distantPast, services.now().addingTimeInterval(Double(intervalMinutes) * 60))
                }
            }
        }
    }

    func applyInterval(_ minutes: Int) {
        intervalMinutes = SubscriptionRefreshPolicy.normalized(minutes)
        if !isDemo { defaults.set(intervalMinutes, forKey: "intervalMinutes"); schedule() }
    }

    private func recordSync(subscription: Subscription?, message: String?) {
        if let repository, let airportID, var source = repository.source(for: airportID) {
            source.syncAttempts.insert(SyncAttempt(date: services.now(), subscription: subscription, message: message), at: 0)
            do { try repository.updateSource(source); syncAttempts = source.syncAttempts }
            catch { settingsMessage = "同步记录未能保存，原记录保留。" }
            return
        }
        syncAttempts.insert(SyncAttempt(date: services.now(), subscription: subscription, message: message), at: 0)
        guard !syncLogBlocked else { return }
        do { try SyncAttemptStore(url: historyStore.url.appendingPathExtension("sync")).save(syncAttempts) }
        catch { settingsMessage = "同步记录未能保存，套餐采样和原记录保留。" }
    }

    func applyStoredSource(_ source: SourceRecord, invalidateRead: Bool = true) {
        if invalidateRead { invalidateRequests() }
        let sameReading = profileID == source.id && latest?.id == source.ledger.samples.last?.id
        let previousError = sameReading ? error : nil
        profileID = source.id; ledger = source.ledger; syncAttempts = source.syncAttempts
        // The saved sample is the success authority. An out-of-order log cannot
        // revive an older failure, and a success log without a saved sample cannot
        // make a failed reading usable. Equal-time failures remain conservative.
        let latestFailure = syncAttempts.filter {
            !$0.succeeded && $0.date.timeIntervalSince1970.isFinite &&
                (0...253402300799).contains($0.date.timeIntervalSince1970) &&
                $0.date >= (latest?.date ?? .distantPast)
        }.max { $0.date < $1.date }
        error = latestFailure.map { $0.message ?? "上次同步未成功，请重试。" } ?? previousError
        resetRule = source.resetRule; thresholdGB = source.threshold
        linkVerificationPending = source.needsVerification
        syncPending = source.needsVerification
        if let airportID, let profile = repository?.snapshot.catalog.profiles.first(where: { $0.id == airportID }) {
            archived = profile.archived
        }
        storageBlocked = false
        do { hasURL = try services.readCredential(source.credentialReference) != nil }
        catch { self.error = error.localizedDescription }
    }

    func configureDemo(ledger: Ledger? = nil, error: String? = nil) {
        guard isDemo else { return }
        if let ledger { self.ledger = ledger }
        self.error = error
        syncAttempts = self.ledger.samples.suffix(8).reversed().map { SyncAttempt(date: $0.date, subscription: $0.subscription, message: nil) }
        if let error { syncAttempts.insert(SyncAttempt(date: Date(), subscription: nil, message: error), at: 0) }
    }

    func dailyRows(from start: Date, to end: Date) -> [DailyUsage] {
        var date = calendar.startOfDay(for: start), rows: [DailyUsage] = []
        let end = min(referenceDate, end)
        while date <= end, rows.count < 3660 {
            guard let period = calendar.dateInterval(of: .day, for: date) else { break }
            rows.append(dayRecord(period)); date = period.end
        }
        return rows
    }

    private func dayRecord(_ period: DateInterval) -> DailyUsage {
        let analysis = currentObservationAnalysis
        if let record = dayRecords[period] { return record }
        var seconds: Double = 0
        for interval in analysis.intervals {
            if interval.canCompare, interval.start >= period.start, interval.end <= period.end,
               interval.duration <= Double(max(1, intervalMinutes)) * 120 {
                seconds += interval.duration
            }
        }
        let report = analysis.usageReport(in: period, calendar: calendar)
        let record = DailyUsage(date: period.start, summary: report.summary, coverage: min(1, seconds / period.duration),
                                hasUnallocated: report.daily.contains(where: \.hasUnallocated),
                                hasExcluded: !report.excluded.isEmpty || !report.partial.isEmpty)
        if dayRecords.count >= 3660 { dayRecords.removeAll(keepingCapacity: true) }
        dayRecords[period] = record
        return record
    }

    func stop() { monitoringStarted = false; invalidateRequests(); timer?.cancel(); timer = nil; reminderRetryTask?.cancel(); reminderRetryTask = nil; nextRefresh = nil; if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver); self.wakeObserver = nil } }
}
