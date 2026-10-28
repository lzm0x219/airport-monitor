import Foundation
import Testing
import TrafficCore
@testable import NativeModels

@Suite @MainActor
struct WorkspaceEditingTests {
    @MainActor final class Fixture {
        let original: NativeRepositoryTests.Fixture
        var now = Date(timeIntervalSince1970: 1_792_497_600)
        var reads = 0
        var sends = 0
        var failSave = false
        var workspace: AirportWorkspace!
        init() throws {
            original = try NativeRepositoryTests.Fixture()
            var services = original.vault.services
            services.now = { self.now }
            services.fetch = { _ in
                self.reads += 1
                return try Subscription(upload: 1_000_000_000, download: 20_000_000_000,
                                        total: 100_000_000_000, expiry: self.now.addingTimeInterval(30 * 86400))
            }
            services.notificationAuthorizationStatus = { .denied }
            services.requestNotificationAuthorization = { false }
            services.reminderServices = ReminderServices(authorizationStatus: { .denied },
                send: { _, _, _ in self.sends += 1 }, queryAcceptance: { _ in .unknown })
            workspace = AirportWorkspace(defaults: original.defaults, historyDirectory: original.root,
                services: services, startAutomatically: false, checkpoint: { point in
                    if self.failSave && point == .beforePublish { throw TrafficError.storage }
                })
        }
        var store: NativeRepository { workspace.repository! }
        func encoded<T: Encodable>(_ value: T) throws -> Data {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            return try encoder.encode(value)
        }
        func cleanup() {
            workspace.profiles.forEach { workspace.model(for: $0).stop() }
            original.cleanup()
        }
    }

    @Test func previewConfirmationUsesItsReadTimeAndCannotCreateTwice() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let count = f.workspace.profiles.count
        let preview = f.workspace.makePreview()
        preview.setInput("https://preview.example/subscription")
        await preview.read()
        #expect(f.reads == 1 && f.workspace.profiles.count == count)
        let readAt = try #require(preview.confirmation?.readAt)
        f.now = f.now.addingTimeInterval(900)
        let id = try #require(await f.workspace.confirmPreview(preview, name: "预览机场"))
        let source = try #require(f.store.source(for: id))
        #expect(source.ledger.samples.count == 1 && source.ledger.samples[0].date == readAt)
        #expect(source.resetRevisions.first?.effectiveAt == readAt)
        let profile = try #require(f.workspace.profiles.first(where: { $0.id == id }))
        #expect(f.workspace.model(for: profile).balanceTrend.forecast.diagnostic != .resetRuleChanged)
        #expect(f.reads == 1 && f.sends == 0)
        #expect(await f.workspace.confirmPreview(preview, name: "重复机场") == nil)
        #expect(f.workspace.profiles.count == count + 1)
        try f.original.assertOriginals()
    }

    @Test func failedConfirmationRetainsPreviewAndCanRetryWithoutReadingAgain() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let preview = f.workspace.makePreview(), count = f.workspace.profiles.count
        preview.setInput("https://preview.example/retry")
        await preview.read(); f.failSave = true
        #expect(await f.workspace.confirmPreview(preview, name: "新机场") == nil)
        #expect(preview.confirmation != nil && f.workspace.profiles.count == count)
        f.failSave = false
        #expect(await f.workspace.confirmPreview(preview, name: "新机场") != nil)
        #expect(f.reads == 1 && f.sends == 0)
        try f.original.assertOriginals()
    }

    @Test func configurationCommitsReminderChoicesAndIdentityTogetherOrNotAtAll() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let profile = f.workspace.profiles[0]
        let original = try f.encoded(f.store.snapshot)
        var reminders = ReminderPreferences(lowEnabled: false, forecastEnabled: true, expiryEnabled: true,
                                             lowThreshold: 0, expiryLeadDays: 3)
        var reset = f.workspace.model(for: profile).resetRule; reset.kind = .monthly; reset.day = 12
        f.failSave = true
        #expect(!(await f.workspace.save(profile: profile, name: "修改名称", plan: "新套餐",
            subscription: "https://new.example/source", reset: reset, threshold: 10, change: .newSource,
            reminderPreferences: reminders, airportRemindersEnabled: false)))
        #expect(try f.encoded(f.store.snapshot) == original)
        #expect(f.reads == 0 && f.sends == 0)
        f.failSave = false
        #expect(await f.workspace.save(profile: profile, name: "修改名称", plan: "新套餐",
            subscription: "https://new.example/source", reset: reset, threshold: 10, change: .newSource,
            reminderPreferences: reminders, airportRemindersEnabled: false))
        let source = try #require(f.store.source(for: profile.id))
        #expect(source.id != profile.historyID && source.reminderPreferences == reminders)
        #expect(source.airportRemindersEnabled == false && source.resetRule == reset)
        #expect(f.store.history(for: profile.id).count == 2)
        reminders.lowEnabled = true
        #expect(!(await f.workspace.save(profile: profile, name: "无效阈值", plan: "", subscription: "",
            reset: reset, threshold: 10, reminderPreferences: reminders)))
        #expect(f.workspace.profiles.first(where: { $0.id == profile.id })?.name == "修改名称")
        try f.original.assertOriginals()
    }

    @Test func statisticsTimeZonePersistsWithoutChangingSamplesOrResetRules() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let sources = try f.encoded(f.store.snapshot.sources)
        f.failSave = true
        let before = f.workspace.statisticsTimeZoneIdentifier
        #expect(!f.workspace.setStatisticsTimeZone("America/New_York"))
        #expect(f.workspace.statisticsTimeZoneIdentifier == before)
        f.failSave = false
        #expect(f.workspace.setStatisticsTimeZone("America/New_York"))
        #expect(try f.encoded(f.store.snapshot.sources) == sources)
        #expect(f.workspace.model(for: f.workspace.profiles[0]).calendar.timeZone.identifier == "America/New_York")
        #expect(!f.workspace.setStatisticsTimeZone("Not/AZone"))
        let reopened = try f.original.open()
        #expect(reopened.snapshot.statisticsTimeZone == "America/New_York")
        try f.original.assertOriginals()
    }

    @Test func editorDraftCancellationAndDisabledThresholdDoNotMutateStoredChoices() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let before = try f.encoded(f.store.snapshot)
        let session = AirportEditingSession(workspace: f.workspace, profile: f.workspace.profiles[0])
        session.draft.name = "仅草稿"
        session.replacing = true; session.draft.subscription = "invalid"; session.change = .newSource
        #expect(session.validate(requiresSubscription: true) == .subscription)
        session.cancelReplacement()
        #expect(session.draft.name == "仅草稿" && session.draft.subscription.isEmpty && session.change == .sameSource)
        session.reminders.lowEnabled = false
        session.thresholdText = "0"; session.reminders.lowThreshold = 0
        #expect(session.validate(requiresSubscription: false) == nil)
        session.reminders.lowEnabled = true
        #expect(session.validate(requiresSubscription: false) == .threshold)
        #expect(try f.encoded(f.store.snapshot) == before && f.sends == 0)
    }

    @Test func disablingRemindersWithIncompleteNumbersPreservesLastValidChoices() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let profile = f.workspace.profiles[0]
        let session = AirportEditingSession(workspace: f.workspace, profile: profile)
        #expect(session.draft.plan == profile.plan)
        session.reminders.thresholdMode = .percent
        session.reminders.lowEnabled = true; session.reminders.expiryEnabled = true
        session.thresholdText = "12"; session.updateThresholdValue(from: session.thresholdText)
        session.expiryDaysText = "5"; session.updateExpiryValue(from: session.expiryDaysText)
        session.thresholdText = "99"; session.updateThresholdValue(from: session.thresholdText)
        session.expiryDaysText = ""; session.updateExpiryValue(from: session.expiryDaysText)
        #expect(session.validate(requiresSubscription: false) == .threshold)
        session.airportRemindersEnabled = false
        #expect(session.validate(requiresSubscription: false) == nil)
        #expect(session.reminders.lowThreshold == 12 && session.reminders.expiryLeadDays == 5)
        #expect(await f.workspace.save(profile: profile, name: session.draft.name, plan: session.draft.plan,
            subscription: "", reset: session.draft.resetRule, threshold: session.draft.threshold,
            reminderPreferences: session.reminders, airportRemindersEnabled: false))
        let reopened = AirportEditingSession(workspace: f.workspace, profile: profile)
        #expect(!reopened.airportRemindersEnabled && reopened.reminders.lowEnabled && reopened.reminders.expiryEnabled)
        #expect(reopened.reminders.lowThreshold == 12 && reopened.reminders.expiryLeadDays == 5)
        #expect(f.reads == 0 && f.sends == 0)
        try f.original.assertOriginals()
    }

    @Test func editorReminderNumbersKeepTheirBoundariesAndLastValidValues() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let session = AirportEditingSession(workspace: f.workspace, profile: f.workspace.profiles[0])
        session.airportRemindersEnabled = true
        session.reminders.lowEnabled = true; session.reminders.expiryEnabled = true
        session.expiryDaysText = "7"; session.reminders.expiryLeadDays = 7
        let thresholds: [(ReminderPreferences.ThresholdMode, String, Double?)] = [
            (.percent, "", nil), (.percent, "0.999", nil), (.percent, "1", 1),
            (.percent, "50", 50), (.percent, "50.001", nil), (.percent, "NaN", nil),
            (.legacyAbsoluteGB, "0", nil), (.legacyAbsoluteGB, "0.001", 0.001),
            (.legacyAbsoluteGB, "1000000", 1_000_000), (.legacyAbsoluteGB, "1000001", nil),
            (.legacyAbsoluteGB, "inf", nil)
        ]
        for (mode, text, expected) in thresholds {
            session.reminders.thresholdMode = mode; session.reminders.lowThreshold = 10
            session.thresholdText = text; session.updateThresholdValue(from: text)
            #expect(session.reminders.lowThreshold == (expected ?? 10))
            #expect(session.validate(requiresSubscription: false) == (expected == nil ? .threshold : nil))
        }

        session.reminders.thresholdMode = .percent; session.reminders.lowThreshold = 10
        session.thresholdText = "10"
        for (text, expected) in [("", nil), ("1", nil), ("2", 2), ("30", 30),
                                 ("31", nil), ("2.0", nil)] as [(String, Int?)] {
            session.reminders.expiryLeadDays = 7
            session.expiryDaysText = text; session.updateExpiryValue(from: text)
            #expect(session.reminders.expiryLeadDays == (expected ?? 7))
            #expect(session.validate(requiresSubscription: false) == (expected == nil ? .expiry : nil))
        }

        session.thresholdText = "0"; session.expiryDaysText = "1"
        #expect(session.validate(requiresSubscription: false) == .threshold)
        #expect(session.fieldErrors[.threshold] == "低余量阈值需为 1–50%。")
        #expect(session.fieldErrors[.expiry] == "首次提醒需提前 2–30 天。")
        session.reminders.lowEnabled = false; session.reminders.expiryEnabled = false
        #expect(session.validate(requiresSubscription: false) == nil)
        #expect(session.reminders.lowThreshold == 10 && session.reminders.expiryLeadDays == 7)
        session.airportRemindersEnabled = false; session.reminders.lowThreshold = .nan
        #expect(session.validate(requiresSubscription: false) == .threshold)
        #expect(session.fieldErrors[.threshold] == "提醒阈值必须是有限数值。")
        #expect(f.reads == 0 && f.sends == 0)
        try f.original.assertOriginals()
    }

    @Test func subscriptionCooldownCoversManualAutomaticPreviewReplacementAndReopen() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.now = f.now.addingTimeInterval(30 * 86400)
        let gate = SubscriptionRequestGate(storeURL: f.original.root.appendingPathComponent("test-request-gate.json"))
        var services = f.original.vault.services
        services.now = { f.now }
        services.nextSubscriptionRequest = { try gate.nextAllowedDate(for: $0, observedAttempt: $1, now: f.now) }
        services.fetch = { url in
            try gate.reserve(url, now: f.now)
            f.reads += 1
            throw TrafficError.network(-1009)
        }
        services.reminderServices = ReminderServices(authorizationStatus: { .denied }, send: { _, _, _ in f.sends += 1 }, queryAcceptance: { _ in .unknown })
        func open() -> AirportWorkspace {
            AirportWorkspace(defaults: f.original.defaults, historyDirectory: f.original.root,
                             services: services, startAutomatically: false)
        }
        var workspace = open()
        let profile = workspace.profiles[0]
        let model = workspace.model(for: profile)
        let before = try f.encoded(model.ledger)
        await model.refresh()
        #expect(f.reads == 1)
        let attempts = model.syncAttempts.count
        await model.refresh(); await model.refresh(purpose: .automatic)
        model.setLifecycle(enabled: false, archived: false)
        model.setLifecycle(enabled: true, archived: false, refreshOnResume: false)
        await model.refresh()
        #expect(f.reads == 1 && model.syncAttempts.count == attempts)
        #expect(model.requestWaitingMessage?.contains("72小时") == true)
        #expect(try f.encoded(model.ledger) == before)
        let currentSource = try #require(workspace.currentSource(for: profile))
        let storedSecret = try services.readCredential(currentSource.credentialReference)
        let secret = try #require(storedSecret)
        let preview = workspace.makePreview(); preview.setInput(secret); await preview.read()
        if case .failed(let message) = preview.state { #expect(message.contains("72小时")) }
        else { Issue.record("Preview must be throttled") }
        #expect(await workspace.save(profile: profile, name: profile.name, plan: profile.plan, subscription: secret,
                                     reset: model.resetRule, threshold: model.thresholdGB, change: .sameSource))
        await model.refresh()
        #expect(f.reads == 1)
        let historyCount = workspace.sourceHistory(for: profile).count
        #expect(await workspace.save(profile: profile, name: profile.name, plan: profile.plan, subscription: secret,
                                     reset: model.resetRule, threshold: model.thresholdGB, change: .newSource))
        await model.refresh()
        #expect(f.reads == 1 && workspace.sourceHistory(for: profile).count == historyCount + 1)
        #expect(workspace.archive(profile, archived: true))
        #expect(workspace.archive(workspace.profiles.first { $0.id == profile.id }!, archived: false))
        await model.refresh()
        model.stop()
        workspace = open()
        let reopened = workspace.model(for: workspace.profiles.first { $0.id == profile.id }!)
        defer { reopened.stop() }
        await reopened.refresh()
        #expect(f.reads == 1 && f.sends == 0)
        f.now = f.now.addingTimeInterval(72 * 3600)
        await reopened.refresh()
        #expect(f.reads == 2 && f.sends == 0)
        try f.original.assertOriginals()
    }
}
