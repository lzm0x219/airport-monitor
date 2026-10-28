import Foundation
import Testing
import TrafficCore
@testable import NativeModels

/// Acceptance-only fault replay. Every dependency is a temporary file, an isolated
/// defaults suite, or an injected in-memory service; never a live subscription.
@Suite @MainActor
struct AcceptanceRecoveryTests {
    @Test(arguments: [RepositoryCheckpoint.migrationPrepared, .migrationPublished])
    func repeatedMigrationRecoveryDoesNotRewriteLegacyOrDuplicateSamples(point: RepositoryCheckpoint) throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        #expect(throws: RepositoryInterruption.self) {
            try f.open { if $0 == point { throw RepositoryInterruption.simulatedCrash } }
        }
        let recovered = try f.open()
        let state = try Data(contentsOf: recovered.stateURL)
        let revision = recovered.snapshot.revision
        let samples = recovered.snapshot.sources.flatMap { $0.ledger.samples.map(\.id) }
        for _ in 0..<5 {
            let reopened = try f.open()
            #expect(reopened.snapshot.revision == revision)
            #expect(try Data(contentsOf: reopened.stateURL) == state)
            #expect(reopened.snapshot.sources.flatMap { $0.ledger.samples.map(\.id) } == samples)
            #expect(reopened.snapshot.sources.count == 2)
            #expect(!reopened.recoveryPending)
            try f.assertOriginals()
        }
        #expect(f.vault.fetches == 0 && f.vault.credentials.count == 2)
        let stateText = String(decoding: state, as: UTF8.self)
        #expect(!stateText.contains("https://"))
    }

    @Test func duplicateArchiveRestoreAndLateFailureKeepOneGapAndOneNewSample() async throws {
        let f = try WorkspaceLifecycleTests.Fixture(); defer { f.cleanup() }
        let before = try #require(f.store.source(for: f.main.id))
        let old = Task { await f.model.refresh() }
        try await f.fetches.waitFor(1)
        #expect(f.workspace.archive(f.main, archived: true))
        #expect(f.workspace.archive(f.main, archived: true))
        let newPrimary = f.workspace.menuAirport
        #expect(newPrimary == f.workspace.profiles[2].id)
        #expect(f.workspace.archive(f.main, archived: false))
        #expect(f.workspace.archive(f.main, archived: false))
        try await f.fetches.waitFor(2)
        f.fetches.fail(0)
        await old.value
        #expect(f.model.busy && f.model.error == nil)
        try f.fetches.succeed(1, used: 900)
        try await f.waitUntilIdle(f.model)
        let recovered = try #require(f.store.source(for: f.main.id))
        let bytes = try Data(contentsOf: f.store.stateURL)
        for _ in 0..<5 { #expect(f.workspace.archive(f.main, archived: false)) }
        #expect(try Data(contentsOf: f.store.stateURL) == bytes)
        #expect(f.fetches.requests.count == 2)
        #expect(recovered.gaps.count == 1 && recovered.gaps[0].restoredAt != nil)
        #expect(recovered.ledger.samples.count == before.ledger.samples.count + 1)
        #expect(recovered.syncAttempts.count == before.syncAttempts.count + 1)
        #expect(f.workspace.menuAirport == newPrimary)
        let reopened = try f.original.open()
        #expect(reopened.source(for: f.main.id)?.ledger.samples.map(\.id) == recovered.ledger.samples.map(\.id))
        #expect(reopened.source(for: f.main.id)?.gaps.count == 1)
        try f.original.assertOriginals()
    }

    @Test func repeatedExplicitSnapshotRecoveryPreservesDamagedAndNewerData() throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        let store = try f.open()
        _ = try f.change(store, mode: .newSource)
        let newer = try Data(contentsOf: store.stateURL)
        let damaged = Data("acceptance-synthetic-damaged-state".utf8)
        try damaged.write(to: store.stateURL)
        #expect(throws: (any Error).self) { try f.open() }
        // Keep the newer committed bytes alongside the exercise so rollback
        // cannot be mistaken for a lossless downgrade of newly collected data.
        let retainedNewer = f.root.appendingPathComponent("acceptance-retained-v2.json")
        try newer.write(to: retainedNewer)
        try NativeRepository.restorePreviousSnapshot(root: f.root)
        let restored = try f.open()
        let recoveredBytes = try Data(contentsOf: restored.stateURL)
        for _ in 0..<3 {
            try NativeRepository.restorePreviousSnapshot(root: f.root)
            let reopened = try f.open()
            #expect(try Data(contentsOf: reopened.stateURL) == recoveredBytes)
            #expect(reopened.source(for: f.first.id)?.id == f.first.historyID)
            #expect(reopened.source(for: f.first.id)?.ledger.samples.count == 2)
        }
        let preserved = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("preserved-") }
        #expect(preserved.count == 4)
        #expect(try preserved.contains { try Data(contentsOf: $0) == damaged })
        #expect(try Data(contentsOf: retainedNewer) == newer)
        #expect(f.vault.credentials.count == 3)
        try f.assertOriginals()
    }

    @Test func repeatedCrashReconciliationNeverResubmitsAcceptedReminder() async throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        var failPersistence = false
        let store = try f.open { if failPersistence && $0 == .beforePublish { throw TrafficError.storage } }
        let clock = ReminderDeliveryTests.Clock()
        try ReminderDeliveryTests().prepare(store, f.first.id)
        clock.onSend = { failPersistence = true }
        let coordinator = ReminderCoordinator(repository: store, services: clock.services)
        #expect(await coordinator.evaluate(airportID: f.first.id, inputProvider: { clock.input }) == .storageFailure)
        #expect(clock.sends.count == 1)
        let identifier = try #require(store.source(for: f.first.id)?.reminderDelivery?.id)
        clock.onSend = nil; clock.query = .accepted
        for _ in 0..<5 {
            let reopened = try f.open()
            let restarted = ReminderCoordinator(repository: reopened, services: clock.services)
            #expect(await restarted.evaluate(airportID: f.first.id, inputProvider: { clock.input }) == .idle)
            #expect(reopened.source(for: f.first.id)?.reminderDelivery == nil)
            #expect(reopened.source(for: f.first.id)?.reminderState?.lowNotified == true)
            #expect(clock.sends == [identifier])
        }
        #expect(f.vault.fetches == 0)
        try f.assertOriginals()
    }

    @Test func failedSyncSurvivesRestartAndSuccessfulRetryRestoresCurrentForecast() async throws {
        let f = try ReminderIntegrationTests.Fixture(); defer { f.cleanup() }
        try f.open(); try f.seedForecast(); f.makeModel()
        let originalIDs = f.model.ledger.samples.map(\.id)
        #expect(f.model.forecastResult.estimate != nil)
        f.failFetch = true; f.advance()
        await f.model.refresh()
        #expect(f.model.error != nil && f.model.forecastResult.estimate == nil)
        try f.open(); f.makeModel()
        #expect(f.model.error != nil)
        #expect(f.model.forecastResult.diagnostic == .synchronizationFailed)
        #expect(WorkspacePresentation(model: f.model).usesOldReading)
        #expect(f.model.ledger.samples.map(\.id) == originalIDs)
        f.failFetch = false; f.advance(); f.used += 100_000_000
        await f.model.refresh()
        #expect(f.model.error == nil && f.model.forecastResult.estimate != nil)
        try f.open(); f.makeModel()
        #expect(f.model.error == nil && f.model.forecastResult.estimate != nil)
        #expect(f.model.ledger.samples.count == originalIDs.count + 1)
        try f.original.assertOriginals()
    }

    @Test func restartedFailureAllowsOnlyUnverifiedExpiryUntilSuccessfulRead() async throws {
        let f = try ReminderIntegrationTests.Fixture(); defer { f.cleanup() }
        f.original.defaults.set(false, forKey: "remindersEnabled")
        f.expiry = f.now.addingTimeInterval(6 * 86400)
        try f.open(); try f.seed()
        var source = try f.source()
        source.reminderPreferences = ReminderPreferences()
        try f.store.updateSource(source); f.makeModel()
        f.failFetch = true; f.advance(); await f.model.refresh()
        #expect(f.sends == 0)
        f.original.defaults.set(true, forKey: "remindersEnabled")
        try f.open(); f.makeModel()
        await f.model.evaluateReminders()
        #expect(f.model.error != nil)
        #expect(f.reasons.flatMap { $0 }.map(\.kind) == [.expirySoon])
        #expect(f.reasons.first?.first?.expiryUnverified == true)
        f.failFetch = false; f.advance(); await f.model.refresh()
        #expect(f.reasons.last?.map(\.kind) == [.low])
        #expect(f.sends == 2)
    }

    @Test func recoveryUsesFailureDatesNotArrayOrderAndNewSuccessOrSourceClearsOldError() throws {
        let f = try ReminderIntegrationTests.Fixture(); defer { f.cleanup() }
        try f.open(); try f.seed()
        var source = try f.source()
        source.syncAttempts = [
            SyncAttempt(date: f.now.addingTimeInterval(-10), subscription: nil, message: "旧失败"),
            SyncAttempt(date: f.now.addingTimeInterval(10), subscription: nil, message: "较新失败"),
            SyncAttempt(date: f.now.addingTimeInterval(15), subscription: source.ledger.samples.last?.subscription, message: nil)
        ]
        f.advance(20); try f.store.updateSource(source); f.makeModel()
        #expect(f.model.error == "较新失败")
        source = try f.source()
        try source.ledger.append(Subscription(upload: 0, download: f.used + 100,
                                             total: 100_000_000_000, expiry: f.expiry), at: f.now)
        try f.store.updateSource(source)
        f.model.applyStoredSource(try f.source())
        #expect(f.model.error == nil)
        source = try f.source()
        source.syncAttempts.append(SyncAttempt(date: f.now, subscription: nil, message: "同刻保存失败"))
        try f.store.updateSource(source); f.makeModel()
        #expect(f.model.error == "同刻保存失败")
        _ = try f.original.change(f.store, mode: .newSource)
        f.model.applyStoredSource(try f.source())
        #expect(f.model.error == nil && f.model.latest == nil)
        try f.original.assertOriginals()
    }

    @Test func reapplyingSameSourceCannotClearUnpersistedStorageFailure() async throws {
        let f = try ReminderIntegrationTests.Fixture(); defer { f.cleanup() }
        try f.open(); try f.seedForecast(); f.makeModel()
        let sampleID = f.model.latest?.id
        f.failCommit = true; f.advance()
        await f.model.refresh()
        #expect(f.model.error != nil)
        #expect(f.model.latest?.id == sampleID)
        f.failCommit = false
        f.model.applyStoredSource(try f.source())
        #expect(f.model.error != nil && f.model.forecastResult.estimate == nil)
        #expect(f.model.latest?.id == sampleID)
        #expect(f.sends == 0)
        f.advance(); await f.model.refresh()
        #expect(f.model.error == nil && f.model.latest?.id != sampleID)
    }
}
