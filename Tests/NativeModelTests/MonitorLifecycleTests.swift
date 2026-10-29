import Foundation
import Testing
import TrafficCore
@testable import NativeModels

@Suite @MainActor
struct MonitorLifecycleTests {
    func model(_ f: NativeRepositoryFixture, _ store: NativeRepository, _ transport: UncooperativeTransport) -> MonitorModel {
        var services = f.vault.services
        services.fetch = { try await transport.fetch($0) }
        services.requestNotificationAuthorization = { false }
        return MonitorModel(profileID: f.first.historyID, credentialAccount: f.first.credentialAccount,
                            defaults: f.defaults, services: services, historyDirectory: f.root,
                            startAutomatically: false, repository: store, airportID: f.first.id)
    }

    @Test(arguments: [false, true]) func stoppedRequestCannotWrite(success: Bool) async throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open(), transport = UncooperativeTransport(), m = model(f, store, transport)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(store.snapshot)
        let task = Task { await m.refresh() }
        try await transport.waitFor(1)
        m.stop()
        if success { try transport.succeed(0) } else { transport.fail(0) }
        await task.value
        #expect(!m.busy); #expect(m.error == nil)
        #expect(try encoder.encode(store.snapshot) == before)
        try f.assertOriginals()
    }

    @Test(arguments: [false, true])
    func oldCompletionCannotClearNewRequestBusyOrOverwriteItsResult(success: Bool) async throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open(), transport = UncooperativeTransport(), m = model(f, store, transport)
        defer { m.stop() }
        let old = Task { await m.refresh() }; try await transport.waitFor(1)
        m.invalidateRequests()
        let current = Task { await m.refresh() }; try await transport.waitFor(2)
        if success { try transport.succeed(0, used: 333) } else { transport.fail(0) }
        await old.value
        #expect(m.busy); #expect(m.error == nil)
        try transport.succeed(1); await current.value
        #expect(!m.busy); #expect(m.latest?.subscription.download == 700)
        #expect(m.syncAttempts.count == 1)
    }

    @Test func previewAndSyncShareThePersistentSeventyTwoHourGate() async throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open()
        let gateURL = f.root.appendingPathComponent("isolated-request-gate.json")
        let previewGate = SubscriptionRequestGate(storeURL: gateURL)
        let syncGate = SubscriptionRequestGate(storeURL: gateURL)
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var fetches = 0
        var services = f.vault.services
        services.now = { now }
        services.nextSubscriptionRequest = { url, attempt in
            try await syncGate.nextAllowedDateAsync(for: url, observedAttempt: attempt, now: now)
        }
        services.fetch = { url in
            try syncGate.reserve(url, now: now)
            fetches += 1
            return try TrafficCore.Subscription(upload: 120, download: 700, total: 10000)
        }
        var reminders = ReminderServices()
        reminders.authorizationStatus = { .denied }
        reminders.send = { _, _, _ in Issue.record("No real or simulated notification should be sent") }
        reminders.queryAcceptance = { _ in .unknown }
        reminders.now = { now }
        services.reminderServices = reminders

        let preview = SubscriptionPreview(fetch: { url in
            try previewGate.reserve(url, now: now)
            fetches += 1
            return try TrafficCore.Subscription(upload: 120, download: 700, total: 10000)
        }, now: services.now)
        preview.setInput("https://a.example/old-secret")
        await preview.read()
        #expect(preview.confirmation != nil)
        let m = MonitorModel(profileID: f.first.historyID, credentialAccount: f.first.credentialAccount,
                             defaults: f.defaults, services: services, historyDirectory: f.root,
                             startAutomatically: false, repository: store, airportID: f.first.id)
        defer { m.stop() }
        let originalSamples = m.ledger.samples.count
        await m.refresh()
        #expect(fetches == 1)
        #expect(m.ledger.samples.count == originalSamples)
        #expect(m.error == nil)
        #expect(m.requestAvailableAt == now.addingTimeInterval(72 * 3600))

        now.addTimeInterval(72 * 3600)
        await m.refresh()
        #expect(fetches == 2)
        #expect(m.ledger.samples.count == originalSamples + 1)
        #expect(m.error == nil)
    }

    @Test func callerCancellationDoesNotRecordFailureOrSample() async throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open(), transport = UncooperativeTransport(), m = model(f, store, transport)
        defer { m.stop() }
        let ids = m.ledger.samples.map(\.id)
        let task = Task { await m.refresh() }; try await transport.waitFor(1)
        task.cancel(); try transport.succeed(0); await task.value
        #expect(m.ledger.samples.map(\.id) == ids)
        #expect(m.syncAttempts.isEmpty); #expect(m.error == nil); #expect(!m.busy)
    }

    @Test func pausedManualSyncIsAllowedAndDoesNotEnableAutomaticSync() async throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open(), transport = UncooperativeTransport(), m = model(f, store, transport)
        defer { m.stop() }
        var catalog = store.snapshot.catalog; catalog.profiles[0].enabled = false
        try store.updateCatalog(catalog)
        m.setLifecycle(enabled: false, archived: false)
        await m.refresh(purpose: .automatic)
        #expect(transport.pending.isEmpty)
        let manual = Task { await m.refresh() }; try await transport.waitFor(1)
        try transport.succeed(0); await manual.value
        #expect(!m.enabled); #expect(!m.syncPending); #expect(m.nextRefresh == nil)
        #expect(store.snapshot.catalog.profiles[0].enabled == false)
        #expect(m.latest?.subscription.download == 700)
    }

    @Test(arguments: [false, true]) func sameSourceReplacementRejectsOldSuccessAndFailure(success: Bool) async throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open(), transport = UncooperativeTransport(), m = model(f, store, transport)
        defer { m.stop() }
        let task = Task { await m.refresh() }; try await transport.waitFor(1)
        _ = try f.change(store)
        m.applyStoredSource(try #require(store.source(for: f.first.id)))
        let ids = m.ledger.samples.map(\.id)
        if success { try transport.succeed(0) } else { transport.fail(0) }
        await task.value
        #expect(m.linkVerificationPending); #expect(m.syncPending)
        #expect(m.error == nil); #expect(m.syncAttempts.isEmpty)
        #expect(m.ledger.samples.map(\.id) == ids)
    }

    @Test func busyPreferenceSaveIsNotLostWhenFetchCompletes() async throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open(), transport = UncooperativeTransport(), m = model(f, store, transport)
        defer { m.stop() }
        let sampleCount = m.ledger.samples.count
        let task = Task { await m.refresh() }; try await transport.waitFor(1)
        var reset = f.rule; reset.day = 15
        await m.savePreferences(interval: 30, reminders: false, threshold: 42, reset: reset)
        #expect(m.busy); #expect(m.thresholdGB == 42); #expect(m.resetRule == reset)
        try transport.succeed(0); await task.value
        let source = try #require(store.source(for: f.first.id))
        #expect(source.threshold == 42); #expect(source.resetRule == reset)
        #expect(source.ledger.samples.count == sampleCount + 1)
        #expect(m.intervalMinutes == 4320); #expect(m.error == nil)
    }

    @Test func globalPreferencesDoNotRewriteSourceWhileBusy() async throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open(), transport = UncooperativeTransport(), m = model(f, store, transport)
        defer { m.stop() }
        let revision = store.snapshot.revision
        let task = Task { await m.refresh() }; try await transport.waitFor(1)
        await m.applyGlobalPreferences(interval: 15, reminders: true)
        #expect(m.busy); #expect(m.remindersEnabled)
        #expect(f.defaults.bool(forKey: "remindersEnabled"))
        #expect(store.snapshot.revision == revision)
        transport.fail(0); await task.value
        #expect(m.remindersEnabled); #expect(m.error != nil)
    }
}
