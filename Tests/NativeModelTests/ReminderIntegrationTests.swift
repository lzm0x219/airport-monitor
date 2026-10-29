import Foundation
import Testing
import TrafficCore
import UserNotifications
@testable import NativeModels

/// Every dependency is isolated: these tests never request system authorization
/// and never hand a notification to UNUserNotificationCenter.
@Suite @MainActor
struct ReminderIntegrationTests {
    @Test func sameSourceRotationAndRestartKeepDeduplicationButNewSourceIsIndependent() async throws {
        let f = try ReminderIntegrationFixture(); defer { f.cleanup() }
        try f.open(); try f.seed(); f.makeModel()
        await f.model.evaluateReminders()
        #expect(f.sends == 1)
        let oldID = f.model.currentProfileID, originalSamples = f.model.ledger.samples.map(\.id)
        f.advance()
        #expect(await f.model.saveSubscription("https://a.example/replacement-token"))
        #expect(f.model.currentProfileID == oldID && f.sends == 1)
        #expect(f.model.ledger.samples.first?.id == originalSamples.first)
        try f.open(); f.makeModel()
        await f.model.evaluateReminders()
        #expect(f.sends == 1)
        f.advance()
        #expect(await f.model.saveSubscription("https://other.example/new-source", change: .newSource))
        #expect(f.model.currentProfileID != oldID && f.sends == 2)
        #expect(f.store.history(for: f.original.first.id).first { $0.id == oldID }?.reminderState?.lowNotified == true)
        #expect(try f.source().reminderState?.lowNotified == true)
        try f.original.assertOriginals()
    }

    @Test func pauseAndArchiveSuppressManualReadsAndResumeDoesNotResendAcceptedRisk() async throws {
        let f = try ReminderIntegrationFixture(); defer { f.cleanup() }
        try f.open(); try f.seed(); f.makeModel()
        await f.model.evaluateReminders()
        #expect(f.sends == 1)
        f.model.setLifecycle(enabled: false, archived: false, refreshOnResume: false)
        f.advance(); await f.model.refresh()
        #expect(f.sends == 1 && !f.model.enabled)
        f.model.setLifecycle(enabled: true, archived: false, refreshOnResume: false)
        f.advance(); await f.model.refresh()
        #expect(f.sends == 1)
        f.model.setLifecycle(enabled: true, archived: true, refreshOnResume: false)
        f.advance(); await f.model.evaluateReminders()
        #expect(f.sends == 1)
        f.model.setLifecycle(enabled: true, archived: false, refreshOnResume: false)
        f.advance(); await f.model.refresh()
        #expect(f.sends == 1)
        #expect(try f.source().reminderState?.lowNotified == true)
    }

    @Test func globalDisablePreservesTypeChoicesAndReenableOnlyUsesSelectedTypes() async throws {
        let f = try ReminderIntegrationFixture(); defer { f.cleanup() }
        f.expiry = f.now.addingTimeInterval(6 * 86400)
        try f.open(); try f.seed(); f.makeModel()
        await f.model.applyGlobalPreferences(reminders: false)
        let preferences = ReminderPreferences(lowEnabled: false, forecastEnabled: false, expiryEnabled: true)
        #expect(await f.model.saveReminderPreferences(preferences, enabled: true))
        await f.model.evaluateReminders()
        #expect(f.sends == 0)
        #expect(try f.source().reminderPreferences == preferences)
        await f.model.applyGlobalPreferences(reminders: true)
        await f.model.evaluateReminders()
        #expect(f.sends == 1)
        #expect(f.reasons.flatMap { $0 }.map(\.kind) == [.expirySoon])
        await f.model.applyGlobalPreferences(reminders: false)
        #expect(try f.source().reminderPreferences == preferences)
        #expect(try f.source().reminderState?.expiryRecords.count == 1)
    }

    @Test func failedSyncOnlyEvaluatesLastKnownExpiryAndMarksItUnverified() async throws {
        let f = try ReminderIntegrationFixture(); defer { f.cleanup() }
        f.expiry = f.now.addingTimeInterval(6 * 86400)
        try f.open(); try f.seed()
        var source = try f.source()
        source.reminderPreferences = ReminderPreferences()
        try f.store.updateSource(source); f.makeModel()
        f.failFetch = true; f.advance()
        await f.model.refresh()
        #expect(f.model.error != nil)
        #expect(f.sends == 1)
        #expect(f.reasons.flatMap { $0 }.map(\.kind) == [.expirySoon])
        #expect(f.reasons.first?.first?.expiryUnverified == true)
        #expect(f.model.latest?.id == source.ledger.samples.last?.id)
        f.failFetch = false; f.advance(); await f.model.refresh()
        #expect(f.sends == 2)
        #expect(f.reasons.last?.map(\.kind) == [.low])
    }

    @Test func staleReadingCanUpgradeExpiryWithoutRetriggeringLowBalance() async throws {
        let f = try ReminderIntegrationFixture(); defer { f.cleanup() }
        f.expiry = f.now.addingTimeInterval(6 * 86400)
        try f.open(); try f.seed()
        var source = try f.source(); source.reminderPreferences = ReminderPreferences()
        try f.store.updateSource(source); f.makeModel()
        await f.model.evaluateReminders()
        #expect(f.sends == 1)
        #expect(Set(f.reasons[0].map(\.kind)) == [.low, .expirySoon])
        f.advance(5 * 86400 + 1)
        await f.model.evaluateReminders()
        #expect(f.sends == 2 && f.model.stale)
        #expect(f.reasons.last?.map(\.kind) == [.expiryDay])
        #expect(f.reasons.last?.first?.expiryUnverified == true)
        await f.model.evaluateReminders()
        #expect(f.sends == 2)
    }

    @Test func failedPreferenceSaveDoesNotSendOrAlterSelectionAndHistory() async throws {
        let f = try ReminderIntegrationFixture(); defer { f.cleanup() }
        try f.open(); try f.seed(); f.makeModel()
        let before = try Data(contentsOf: f.store.stateURL)
        f.failCommit = true
        #expect(!(await f.model.saveReminderPreferences(ReminderPreferences(), enabled: false)))
        #expect(f.sends == 0)
        #expect(try Data(contentsOf: f.store.stateURL) == before)
        f.failCommit = false
        #expect(await f.model.saveReminderPreferences(ReminderPreferences(lowEnabled: false, forecastEnabled: false,
                                                                        expiryEnabled: true), enabled: true))
        #expect(f.sends == 0)
        try f.original.assertOriginals()
    }

    @Test func failedFreshReadingSaveCannotCreateNewLowRiskNotification() async throws {
        let f = try ReminderIntegrationFixture(); defer { f.cleanup() }
        f.used = 10_000_000_000
        try f.open(); try f.seed(); f.makeModel()
        let ids = f.model.ledger.samples.map(\.id)
        f.used = 99_000_000_000; f.advance(); f.failCommit = true
        await f.model.refresh()
        #expect(f.sends == 0 && f.model.error != nil)
        #expect(f.model.ledger.samples.map(\.id) == ids)
        #expect(try f.source().reminderState?.lowNotified == false)
        f.failCommit = false; await f.model.refresh()
        #expect(f.sends == 1)
    }

    @Test func migratedLegacyRiskIsNotReissuedOnFirstSuccessfulRefresh() async throws {
        let f = try ReminderIntegrationFixture(); defer { f.cleanup() }
        try f.open(); f.makeModel()
        #expect(f.model.ledger.lowBalanceNotified)
        await f.model.refresh()
        #expect(f.sends == 0)
        #expect(try f.source().reminderState?.lowNotified == true)
        try f.original.assertOriginals()
    }

    @Test func missingPermissionDoesNotSendOrPretendRiskWasAccepted() async throws {
        let f = try ReminderIntegrationFixture(); defer { f.cleanup() }
        try f.open(); try f.seed(); f.makeModel(); f.authorization = .denied
        await f.model.evaluateReminders()
        #expect(f.sends == 0 && f.authorizationRequests == 0)
        #expect(try f.source().reminderState?.lowNotified == false)
        f.authorization = .authorized
        await f.model.evaluateReminders()
        #expect(f.sends == 1)
    }

    @Test(arguments: ["airport", "paused", "archived", "allTypes"])
    func eachScopeSuppressesAnUnsentRiskWithoutErasingHistory(scope: String) async throws {
        let f = try ReminderIntegrationFixture(); defer { f.cleanup() }
        try f.open(); try f.seed(); f.makeModel()
        let ids = f.model.ledger.samples.map(\.id)
        if scope == "airport" {
            #expect(await f.model.saveReminderPreferences(ReminderPreferences(forecastEnabled: false, expiryEnabled: false), enabled: false))
        } else if scope == "allTypes" {
            #expect(await f.model.saveReminderPreferences(ReminderPreferences(lowEnabled: false, forecastEnabled: false,
                                                                            expiryEnabled: false), enabled: true))
        } else {
            f.model.setLifecycle(enabled: scope != "paused", archived: scope == "archived", refreshOnResume: false)
        }
        await f.model.evaluateReminders()
        #expect(f.sends == 0)
        #expect(f.model.ledger.samples.map(\.id) == ids)
        #expect(try f.source().reminderState?.lowNotified != true)
    }

    @Test func successfulRefreshCanConfirmForecastAfterBusyRequestCompletes() async throws {
        let f = try ReminderIntegrationFixture(); defer { f.cleanup() }
        try f.open(); try f.seedForecast(); f.makeModel()
        #expect(f.model.forecastResult.estimate != nil)
        f.advance(); f.used += 10_000_000
        await f.model.refresh()
        #expect(f.sends == 0)
        f.advance(); f.used += 10_000_000
        await f.model.refresh()
        #expect(f.sends == 1)
        #expect(f.reasons.first?.map(\.kind) == [.forecast])
    }

    @Test func failedReadBreaksForecastConfirmationAndRecoveryRequiresTwoFreshObservations() async throws {
        let f = try ReminderIntegrationFixture(); defer { f.cleanup() }
        try f.open(); try f.seedForecast(); f.makeModel()
        f.advance(); await f.model.refresh()
        #expect(f.sends == 0)
        f.failFetch = true; f.advance(); await f.model.refresh()
        #expect(try f.source().reminderState?.forecastTrigger == nil)
        f.failFetch = false; f.advance(); await f.model.refresh()
        #expect(f.sends == 0)
        // Re-evaluation and elapsed time alone must not count as another success.
        f.advance(); await f.model.evaluateReminders()
        #expect(f.sends == 0)
        await f.model.refresh()
        #expect(f.sends == 1)
        #expect(f.reasons.first?.map(\.kind) == [.forecast])
    }

    @Test func newAirportDefaultsAndNewSourcePreservesChoicesWithIndependentRiskState() throws {
        let f = try ReminderIntegrationFixture(); defer { f.cleanup() }
        try f.open()
        let created = try f.store.saveAirport(profile: nil, name: "新增机场", plan: "", subscription: "https://new.example/sub",
                                               reset: ResetRule(), threshold: 7.5)
        let preferences = try #require(f.store.source(for: created.id)?.reminderPreferences)
        #expect(preferences == ReminderPreferences())
        #expect(preferences.thresholdMode == .percent && preferences.lowThreshold == 10)
        var old = try f.source()
        old.reminderPreferences = ReminderPreferences(lowEnabled: false, forecastEnabled: true, expiryEnabled: true,
                                                      lowThreshold: 23, expiryLeadDays: 3)
        old.airportRemindersEnabled = false
        var notified = ReminderState(); notified.forecastNotified = true
        old.reminderState = notified
        try f.store.updateSource(old)
        let replaced = try f.store.saveAirport(profile: f.original.first, name: "新来源", plan: "",
            subscription: "https://another.example/sub", reset: old.resetRule, threshold: old.threshold, change: .newSource)
        #expect(f.store.source(for: replaced.id)?.reminderPreferences == old.reminderPreferences)
        #expect(f.store.source(for: replaced.id)?.airportRemindersEnabled == false)
        #expect(f.store.source(for: replaced.id)?.reminderState == nil)
        #expect(f.store.history(for: replaced.id).first { $0.id == old.id }?.ledger.samples.map(\.id) == old.ledger.samples.map(\.id))
    }

    @Test func oldV2WithoutReminderFieldsDecodesAndUsesLegacyGBWithoutEnablingNewTypes() async throws {
        let f = try ReminderIntegrationFixture(); defer { f.cleanup() }
        try f.open(); try f.seed()
        var source = try f.source(), ledger = Ledger()
        try ledger.append(Subscription(upload: 0, download: 992_000_000_000, total: 1_000_000_000_000,
                                       expiry: f.now.addingTimeInterval(6 * 86400)), at: f.now)
        source.ledger = ledger; source.thresholdMode = .legacyAbsoluteGB; source.threshold = 7.5
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
        for key in ["reminderPreferences", "reminderState", "reminderDelivery", "airportRemindersEnabled"] { json.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(SourceRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.reminderPreferences == nil && legacy.reminderState == nil)
        #expect(legacy.thresholdMode == .legacyAbsoluteGB && legacy.threshold == 7.5)
        #expect(!legacy.notifyForecast && !legacy.notifyExpiry)
        try f.store.updateSource(legacy); try f.open(); f.makeModel()
        await f.model.evaluateReminders()
        // 8 GB is below 10% of this quota, but above the user's preserved 7.5 GB limit.
        // The imminent expiry must also stay silent until the new reminder type is selected.
        #expect(f.sends == 0, "Unexpected reasons: \(f.reasons)")
        #expect(f.model.latest?.subscription.remaining == 8_000_000_000)
    }

    @Test func legacyGBSaveUpdatesActualReminderPolicyAndRepeatedSaveDoesNotResend() async throws {
        let f = try ReminderIntegrationFixture(); defer { f.cleanup() }
        try f.open(); try f.seed(); f.makeModel()
        let rule = try f.source().resetRule
        await f.model.savePreferences(interval: 15, reminders: true, threshold: 4, reset: rule)
        let preferences = try #require(try f.source().reminderPreferences)
        #expect(preferences.thresholdMode == .legacyAbsoluteGB && preferences.lowThreshold == 4)
        #expect(f.sends == 0, "Unexpected reasons: \(f.reasons)") // 5 GB remaining is above 4 GB, though below 10%.
        await f.model.savePreferences(interval: 15, reminders: true, threshold: 6, reset: rule)
        #expect(f.sends == 1)
        await f.model.savePreferences(interval: 15, reminders: true, threshold: 6, reset: rule)
        #expect(f.sends == 1)
        #expect(try f.source().reminderState?.lowNotified == true)
    }

    @Test func savingOtherLegacySettingsWithoutChangingThresholdPreservesPercentageChoice() async throws {
        let f = try ReminderIntegrationFixture(); defer { f.cleanup() }
        try f.open(); try f.seed(); f.makeModel()
        let source = try f.source()
        await f.model.savePreferences(interval: 30, reminders: false, threshold: source.threshold, reset: source.resetRule)
        #expect(try f.source().reminderPreferences == source.reminderPreferences)
        #expect(try f.source().reminderPreferences?.thresholdMode == .percent)
        #expect(f.model.intervalMinutes == 4320 && !f.model.remindersEnabled)
        #expect(f.sends == 0)
    }
}
