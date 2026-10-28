import Foundation
import Testing
import UserNotifications
import TrafficCore
@testable import NativeModels

@Suite @MainActor
struct ReminderDeliveryTests {
    @MainActor final class Clock {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        var sends = [String]()
        var sentReasons = [[ReminderReason.Kind]]()
        var fail = false
        var authorization = UNAuthorizationStatus.authorized
        var query = ReminderAcceptance.unknown
        var onAuthorization: (() async -> Void)?
        var onSend: (() async -> Void)?
        var services: ReminderServices {
            ReminderServices(authorizationStatus: {
                await self.onAuthorization?(); return self.authorization
            }, send: { id, _, reasons in
                self.sends.append(id); self.sentReasons.append(reasons.map(\.kind)); await self.onSend?()
                if self.fail { throw TrafficError.network(-1009) }
            }, queryAcceptance: { _ in self.query }, now: { self.date })
        }
        var input: ReminderInput {
            ReminderInput(now: date, sampleID: UUID(uuidString: "40000000-0000-0000-0000-000000000001"),
                          observedAt: date, remainingBytes: 5, totalBytes: 100, usageFresh: true, globalEnabled: true)
        }
    }

    func prepare(_ store: NativeRepository, _ id: UUID) throws {
        var source = try #require(store.source(for: id))
        source.reminderPreferences = ReminderPreferences(forecastEnabled: false, expiryEnabled: false)
        source.reminderState = ReminderState()
        try store.updateSource(source)
    }

    @Test func failureRetriesAfterFiveMinutesAndOnlyAcceptanceDeduplicates() async throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        let store = try f.open(), clock = Clock(); try prepare(store, f.first.id)
        let coordinator = ReminderCoordinator(repository: store, services: clock.services)
        clock.fail = true
        #expect(await coordinator.evaluate(airportID: f.first.id, inputProvider: { clock.input }) == .retryScheduled)
        #expect(store.source(for: f.first.id)?.reminderState?.lowNotified == false)
        let first = try #require(store.source(for: f.first.id)?.reminderDelivery)
        clock.date += 299; clock.fail = false
        #expect(await coordinator.evaluate(airportID: f.first.id, inputProvider: { clock.input }) == .retryScheduled)
        #expect(clock.sends.count == 1)
        clock.date += 1
        #expect(await coordinator.evaluate(airportID: f.first.id, inputProvider: { clock.input }) == .sent)
        #expect(clock.sends.count == 2 && clock.sends[1] != first.id)
        #expect(store.source(for: f.first.id)?.reminderState?.lowNotified == true)
        #expect(await coordinator.evaluate(airportID: f.first.id, inputProvider: { clock.input }) == .idle)
        try f.assertOriginals()
    }

    @Test func deniedPermissionNeverSubmitsOrCreatesRetry() async throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        let store = try f.open(), clock = Clock(); try prepare(store, f.first.id)
        clock.authorization = .denied
        let coordinator = ReminderCoordinator(repository: store, services: clock.services)
        for _ in 0..<3 { #expect(await coordinator.evaluate(airportID: f.first.id, inputProvider: { clock.input }) == .denied) }
        #expect(clock.sends.isEmpty && store.source(for: f.first.id)?.reminderDelivery == nil)
        clock.authorization = .authorized
        #expect(await coordinator.evaluate(airportID: f.first.id, inputProvider: { clock.input }) == .sent)
    }

    @Test func retryReevaluatesCurrentRiskInsteadOfReplayingFailedReasons() async throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        let store = try f.open(), clock = Clock(); try prepare(store, f.first.id)
        clock.fail = true
        let coordinator = ReminderCoordinator(repository: store, services: clock.services)
        #expect(await coordinator.evaluate(airportID: f.first.id, inputProvider: { clock.input }) == .retryScheduled)
        clock.fail = false; clock.date += 300
        var safe = clock.input; safe.remainingBytes = 80; safe.sampleID = UUID()
        #expect(await coordinator.evaluate(airportID: f.first.id, inputProvider: { safe }) == .idle)
        #expect(clock.sends.count == 1)
        var exhausted = clock.input; exhausted.remainingBytes = 0; exhausted.sampleID = UUID()
        #expect(await coordinator.evaluate(airportID: f.first.id, inputProvider: { exhausted }) == .sent)
        #expect(store.source(for: f.first.id)?.reminderState?.exhaustedNotified == true)
        #expect(clock.sentReasons.last == [.exhausted])
    }

    @Test(arguments: [1, 2]) func storageFailureBeforeIntentionPreventsSubmission(failingCommit: Int) async throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        var block = false, commits = 0
        let store = try f.open {
            if block && $0 == .beforePublish {
                commits += 1
                if commits == failingCommit { throw TrafficError.storage }
            }
        }
        let clock = Clock(); try prepare(store, f.first.id); block = true
        let coordinator = ReminderCoordinator(repository: store, services: clock.services)
        #expect(await coordinator.evaluate(airportID: f.first.id, inputProvider: { clock.input }) == .storageFailure)
        #expect(clock.sends.isEmpty)
    }

    @Test func crashAfterSystemAcceptanceReconcilesWithoutResending() async throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        var block = false
        let store = try f.open { if block && $0 == .beforePublish { throw TrafficError.storage } }
        let clock = Clock(); try prepare(store, f.first.id)
        clock.onSend = { block = true }
        let coordinator = ReminderCoordinator(repository: store, services: clock.services)
        #expect(await coordinator.evaluate(airportID: f.first.id, inputProvider: { clock.input }) == .storageFailure)
        #expect(clock.sends.count == 1)
        #expect(store.source(for: f.first.id)?.reminderDelivery?.status == .pending)
        let reopened = try f.open()
        clock.query = .accepted; clock.onSend = nil
        let restarted = ReminderCoordinator(repository: reopened, services: clock.services)
        #expect(await restarted.evaluate(airportID: f.first.id, inputProvider: { clock.input }) == .idle)
        #expect(clock.sends.count == 1 && reopened.source(for: f.first.id)?.reminderState?.lowNotified == true)
    }

    @Test func unknownAndAbsentPendingRequestsStayUnconfirmed() async throws {
        for acceptance in [ReminderAcceptance.unknown, .notFound] {
            let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
            let store = try f.open(), clock = Clock(); try prepare(store, f.first.id)
            var source = try #require(store.source(for: f.first.id))
            source.reminderDelivery = ReminderDelivery(id: "uncertain", sourceID: source.id,
                reasons: [ReminderReason(kind: .low)], attemptedAt: clock.date, status: .pending)
            try store.updateSource(source)
            clock.query = acceptance
            let coordinator = ReminderCoordinator(repository: store, services: clock.services)
            #expect(await coordinator.evaluate(airportID: f.first.id, inputProvider: { clock.input }) == .unconfirmed)
            clock.date += 86_400
            #expect(await coordinator.evaluate(airportID: f.first.id, inputProvider: { clock.input }) == .unconfirmed)
            #expect(clock.sends.isEmpty)
            #expect(store.source(for: f.first.id)?.reminderDelivery == nil)
            #expect(store.source(for: f.first.id)?.reminderUnconfirmedDeliveries?.first?.status == .unconfirmed)
            var exhausted = clock.input; exhausted.remainingBytes = 0
            #expect(await coordinator.evaluate(airportID: f.first.id, inputProvider: { exhausted }) == .sent)
            #expect(clock.sends.count == 1)
            #expect(store.source(for: f.first.id)?.reminderUnconfirmedDeliveries?.count == 1)
        }
    }

    @Test func simultaneousCoordinatorsSubmitOnce() async throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        let store = try f.open(), clock = Clock(); try prepare(store, f.first.id)
        var suspended: CheckedContinuation<Void, Never>?
        clock.onSend = { await withCheckedContinuation { suspended = $0 } }
        let a = ReminderCoordinator(repository: store, services: clock.services)
        let b = ReminderCoordinator(repository: store, services: clock.services)
        let task = Task { await a.evaluate(airportID: f.first.id, inputProvider: { clock.input }) }
        while suspended == nil { await Task.yield() }
        #expect(await b.evaluate(airportID: f.first.id, inputProvider: { clock.input }) == .idle)
        #expect(clock.sends.count == 1)
        suspended?.resume()
        #expect(await task.value == .sent)
    }

    @Test func staleRepositoryCannotResubmitAcceptedRisk() async throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        let store = try f.open(), clock = Clock(); try prepare(store, f.first.id)
        let stale = try f.open()
        let a = ReminderCoordinator(repository: store, services: clock.services)
        let b = ReminderCoordinator(repository: stale, services: clock.services)
        #expect(await a.evaluate(airportID: f.first.id, inputProvider: { clock.input }) == .sent)
        #expect(await b.evaluate(airportID: f.first.id, inputProvider: { clock.input }) == .storageFailure)
        #expect(clock.sends.count == 1)
    }

    @Test func migrationMarkerSurvivesLegacyLedgerFlagReset() async throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        let store = try f.open(), clock = Clock()
        var source = try #require(store.source(for: f.first.id))
        source.reminderPreferences = ReminderPreferences(forecastEnabled: false, expiryEnabled: false)
        source.reminderState = nil; source.ledger.lowBalanceNotified = false
        #expect(source.migratedNotificationAt != nil)
        try store.updateSource(source)
        let coordinator = ReminderCoordinator(repository: store, services: clock.services)
        #expect(await coordinator.evaluate(airportID: f.first.id, inputProvider: { clock.input }) == .idle)
        #expect(clock.sends.isEmpty)
        #expect(store.source(for: f.first.id)?.reminderState?.lowNotified == true)
    }

    @Test func pauseDuringAuthorizationPreventsSending() async throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        let store = try f.open(), clock = Clock(); try prepare(store, f.first.id)
        clock.onAuthorization = {
            var catalog = store.snapshot.catalog; catalog.profiles[0].enabled = false
            try! store.updateCatalog(catalog)
        }
        let coordinator = ReminderCoordinator(repository: store, services: clock.services)
        #expect(await coordinator.evaluate(airportID: f.first.id, inputProvider: { clock.input }) == .idle)
        #expect(clock.sends.isEmpty)
    }

    @Test(arguments: [false, true]) func offOnWhileAuthorizationWaitsRestartsForecastConfirmation(pause: Bool) async throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        let store = try f.open(), clock = Clock(); try prepare(store, f.first.id)
        var source = try #require(store.source(for: f.first.id))
        source.reminderPreferences = ReminderPreferences(lowEnabled: false, forecastEnabled: true, expiryEnabled: false)
        try store.updateSource(source)
        var input = ReminderInput(now: clock.date, sampleID: UUID(), observedAt: clock.date,
                                  remainingBytes: 20, totalBytes: 100, forecastRequiredBytes: 22,
                                  usageFresh: true, forecastEligible: true, globalEnabled: true)
        let coordinator = ReminderCoordinator(repository: store, services: clock.services)
        #expect(await coordinator.evaluate(airportID: f.first.id, inputProvider: { input }) == .idle)
        input.now += 300; input.observedAt = input.now; input.sampleID = UUID()
        var suspended: CheckedContinuation<Void, Never>?
        clock.onAuthorization = { await withCheckedContinuation { suspended = $0 } }
        let task = Task { await coordinator.evaluate(airportID: f.first.id, inputProvider: { input }) }
        while suspended == nil { await Task.yield() }
        if pause { input.paused = true } else { input.globalEnabled = false }
        #expect(await coordinator.evaluate(airportID: f.first.id, inputProvider: { input }) == .idle)
        #expect(store.source(for: f.first.id)?.reminderState?.forecastTrigger == nil)
        input.paused = false; input.globalEnabled = true
        #expect(await coordinator.evaluate(airportID: f.first.id, inputProvider: { input }) == .idle)
        clock.onAuthorization = nil; suspended?.resume()
        #expect(await task.value == .idle)
        #expect(clock.sends.isEmpty)
        input.now += 300; input.observedAt = input.now; input.sampleID = UUID()
        #expect(await coordinator.evaluate(airportID: f.first.id, inputProvider: { input }) == .idle)
        #expect(clock.sends.isEmpty)
        input.now += 300; input.observedAt = input.now; input.sampleID = UUID()
        #expect(await coordinator.evaluate(airportID: f.first.id, inputProvider: { input }) == .sent)
        #expect(clock.sentReasons == [[.forecast]])
    }

    @Test func sourceReplacementDuringAuthorizationPreventsOldRiskDelivery() async throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        let store = try f.open(), clock = Clock(); try prepare(store, f.first.id)
        clock.onAuthorization = { _ = try! f.change(store, mode: .newSource) }
        let coordinator = ReminderCoordinator(repository: store, services: clock.services)
        #expect(await coordinator.evaluate(airportID: f.first.id, inputProvider: { clock.input }) == .idle)
        #expect(clock.sends.isEmpty && store.source(for: f.first.id)?.reminderDelivery == nil)
    }

    @Test func acceptedWhilePausedStillDeduplicatesOnResume() async throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        let store = try f.open(), clock = Clock(); try prepare(store, f.first.id)
        clock.onSend = {
            var catalog = store.snapshot.catalog; catalog.profiles[0].enabled = false
            try! store.updateCatalog(catalog)
        }
        let coordinator = ReminderCoordinator(repository: store, services: clock.services)
        #expect(await coordinator.evaluate(airportID: f.first.id, inputProvider: { clock.input }) == .sent)
        #expect(store.source(for: f.first.id)?.reminderState?.lowNotified == true)
        var catalog = store.snapshot.catalog; catalog.profiles[0].enabled = true; try store.updateCatalog(catalog)
        #expect(await coordinator.evaluate(airportID: f.first.id, inputProvider: { clock.input }) == .idle)
        #expect(clock.sends.count == 1)
    }

    @Test func lateAcceptanceCannotMarkNewSource() async throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        let store = try f.open(), clock = Clock(); try prepare(store, f.first.id)
        let old = try #require(store.source(for: f.first.id))
        clock.onSend = { _ = try! f.change(store, mode: .newSource) }
        let coordinator = ReminderCoordinator(repository: store, services: clock.services)
        #expect(await coordinator.evaluate(airportID: f.first.id, inputProvider: { clock.input }) == .sent)
        #expect(store.source(for: f.first.id)?.id != old.id)
        #expect(store.source(for: f.first.id)?.reminderState?.lowNotified != true)
        #expect(store.history(for: f.first.id).first(where: { $0.id == old.id })?.reminderDelivery == nil)
        #expect(store.history(for: f.first.id).first(where: { $0.id == old.id })?.reminderState?.lowNotified == true)
        try f.assertOriginals()
    }
}
