import Darwin
import Foundation
import Testing
import TrafficCore
@testable import NativeModels

/// A watchdog can release the test lock even when a regression blocks the main actor.
private final class GateTestLock: @unchecked Sendable {
    private let mutex = NSLock()
    private var descriptor: Int32

    init(url: URL) throws {
        let fd = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw TrafficError.storage }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw TrafficError.storage }
        descriptor = fd
    }

    var isHeld: Bool { mutex.lock(); defer { mutex.unlock() }; return descriptor >= 0 }
    func release() {
        mutex.lock(); let fd = descriptor; descriptor = -1; mutex.unlock()
        if fd >= 0 { flock(fd, LOCK_UN); close(fd) }
    }
    deinit { release() }
}

private final class GateNoNetworkProtocol: URLProtocol {
    private static let mutex = NSLock()
    private static var starts = 0
    static var startCount: Int { mutex.lock(); defer { mutex.unlock() }; return starts }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.mutex.lock(); Self.starts += 1; Self.mutex.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }
    override func stopLoading() {}
}

@MainActor
private final class DeferredGateChecks {
    var calls = 0
    private var pending: [CheckedContinuation<Date?, Error>] = []
    private var resolved = Set<Int>()

    func check() async throws -> Date? {
        calls += 1
        if calls == 1 { return nil }
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func finish(_ index: Int, value: Date?) {
        guard resolved.insert(index).inserted else { return }
        pending[index].resume(returning: value)
    }
    func cancelRemaining() {
        for index in pending.indices where resolved.insert(index).inserted {
            pending[index].resume(throwing: CancellationError())
        }
    }
}

@Suite @MainActor
struct RequestGateConcurrencyTests {
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "Expected asynchronous gate progress")
    }

    @Test func startupRegistrationWaitsAndCanBeCancelled() async throws {
        let attempts = StartupRequestAttempts()
        let older = Date(timeIntervalSince1970: 1_800_000_000)
        let newer = older.addingTimeInterval(3600)
        attempts.include(older, for: "shared")
        var completed = false
        let waiter = Task {
            try await attempts.waitUntilReady()
            completed = true
            return attempts.latest(for: "shared")
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!completed)
        attempts.include(newer, for: "shared")
        attempts.include(older, for: "other")
        attempts.finishRegistration()
        #expect(try await waiter.value == newer)
        #expect(attempts.latest(for: "other") == older)

        let unfinished = StartupRequestAttempts()
        let cancelled = Task { try await unfinished.waitUntilReady() }
        await Task.yield()
        cancelled.cancel()
        do { try await cancelled.value; Issue.record("Cancelled registration wait must throw") }
        catch is CancellationError {} catch { Issue.record("Unexpected registration error: \(error)") }
    }

    @Test(arguments: [false, true], [false, true])
    func startupPreservesSharedAddressHistory(automatic: Bool, sameAddress: Bool) async throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = now.addingTimeInterval(-3600)
        let old = now.addingTimeInterval(-100 * 3600)
        let store = try f.open()
        for (profile, attempt) in [(f.catalog.profiles[0], old), (f.catalog.profiles[1], recent)] {
            var source = try #require(store.source(for: profile.id))
            source.ledger = Ledger()
            source.syncAttempts = [SyncAttempt(date: attempt, subscription: nil, message: "simulated")]
            try store.updateSource(source)
        }
        // The second airport is archived. Its address differs in spelling but
        // identifies the same gate when sameAddress is true.
        f.vault.credentials["legacy-b"] = sameAddress
            ? "https://A.EXAMPLE:443/old-secret"
            : "https://b.example:443/old-secret"
        let gate = SubscriptionRequestGate(storeURL: f.root.appendingPathComponent("startup-gate.json"))
        var services = f.vault.services
        var archivedCheckStarted = false, releaseArchivedCheck = false, activeChecks = 0
        services.now = { now }
        services.nextSubscriptionRequest = { url, attempt in
            if url.port == 443 {
                archivedCheckStarted = true
                while !releaseArchivedCheck { try await Task.sleep(for: .milliseconds(10)) }
            }
            let result = try await gate.nextAllowedDateAsync(for: url, observedAttempt: attempt, now: now)
            if url.port != 443 { activeChecks += 1 }
            return result
        }
        services.fetch = { url in
            try gate.reserve(url, now: now)
            f.vault.fetches += 1
            return try Subscription(upload: 120, download: 260, total: 10000)
        }
        let workspace = AirportWorkspace(defaults: f.defaults, historyDirectory: f.root,
                                         services: services, startAutomatically: automatic)
        defer {
            releaseArchivedCheck = true
            workspace.profiles.forEach { workspace.model(for: $0).stop() }
        }
        let model = workspace.model(for: f.first)
        try await waitUntil { archivedCheckStarted }
        if automatic {
            try await waitUntil { activeChecks >= 2 && (model.settingsMessage != nil || f.vault.fetches > 0) }
        } else {
            await model.refresh()
        }
        if sameAddress {
            #expect(f.vault.fetches == 0)
            #expect(model.requestAvailableAt == recent.addingTimeInterval(72 * 3600))
        } else {
            #expect(f.vault.fetches == 1)
        }
    }

    @Test func previewPreservesSharedAddressHistoryBeforeInitialChecksFinish() async throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        f.catalog.profiles[1].archived = false
        f.catalog.profiles[1].enabled = true
        f.defaults.set(try JSONEncoder().encode(f.catalog), forKey: "airportCatalog.v1")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = now.addingTimeInterval(-3600)
        let store = try f.open()
        for (profile, attempt) in [(f.catalog.profiles[0], now.addingTimeInterval(-100 * 3600)),
                                   (f.catalog.profiles[1], recent)] {
            var source = try #require(store.source(for: profile.id))
            source.ledger = Ledger()
            source.syncAttempts = [SyncAttempt(date: attempt, subscription: nil, message: "simulated")]
            try store.updateSource(source)
        }
        f.vault.credentials["legacy-a"] = "https://a.example:443/old-secret"
        f.vault.credentials["legacy-b"] = "https://A.EXAMPLE:443/old-secret"
        let gate = SubscriptionRequestGate(storeURL: f.root.appendingPathComponent("preview-startup-gate.json"))
        var services = f.vault.services
        var parked = 0, release = false
        services.now = { now }
        services.nextSubscriptionRequest = { url, attempt in
            if url.port == 443 {
                parked += 1
                while !release { try await Task.sleep(for: .milliseconds(10)) }
            }
            return try await gate.nextAllowedDateAsync(for: url, observedAttempt: attempt, now: now)
        }
        services.fetch = { url in
            try gate.reserve(url, now: now)
            f.vault.fetches += 1
            return try Subscription(upload: 120, download: 260, total: 10000)
        }
        let workspace = AirportWorkspace(defaults: f.defaults, historyDirectory: f.root,
                                         services: services, startAutomatically: false)
        defer {
            release = true
            workspace.profiles.forEach { workspace.model(for: $0).stop() }
        }
        try await waitUntil { parked == 2 }
        let preview = workspace.makePreview()
        preview.setInput("https://a.example/old-secret")
        await preview.read()
        #expect(f.vault.fetches == 0)
        guard case .failed(let message) = preview.state else {
            Issue.record("Preview should report the existing cooldown")
            return
        }
        #expect(message == SubscriptionCooldown(until: recent.addingTimeInterval(72 * 3600)).localizedDescription)
    }

    @Test func modelInitializationDoesNotBlockWhileGateIsLocked() async throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open()
        let url = f.root.appendingPathComponent("request-gate.json")
        let gate = SubscriptionRequestGate(storeURL: url)
        let held = try GateTestLock(url: url)
        let watchdog = DispatchWorkItem { held.release() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: watchdog)
        defer { watchdog.cancel(); held.release() }

        var services = f.vault.services
        var completed = false
        services.nextSubscriptionRequest = { url, attempt in
            let result = try await gate.nextAllowedDateAsync(for: url, observedAttempt: attempt)
            completed = true
            return result
        }
        let model = MonitorModel(profileID: f.first.historyID, credentialAccount: f.first.credentialAccount,
                                 defaults: f.defaults, services: services, historyDirectory: f.root,
                                 startAutomatically: false, repository: store, airportID: f.first.id)
        defer { model.stop() }
        #expect(held.isHeld, "Model initialization waited for the gate lock")
        held.release()
        try await waitUntil { completed }
    }

    @Test func cancelledGateLookupDoesNotWaitForOrWriteAfterTheLock() async throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let storeURL = f.root.appendingPathComponent("cancelled-gate.json")
        let gate = SubscriptionRequestGate(storeURL: storeURL)
        let held = try GateTestLock(url: storeURL)
        let watchdog = DispatchWorkItem { held.release() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: watchdog)
        defer { watchdog.cancel(); held.release() }
        let url = URL(string: "https://example.invalid/subscription")!
        let task = Task { try await gate.nextAllowedDateAsync(for: url, observedAttempt: Date()) }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled gate check must throw") }
        catch is CancellationError {} catch { Issue.record("Unexpected gate error: \(error)") }
        #expect(held.isHeld, "Cancellation waited for the gate lock")
        #expect(!FileManager.default.fileExists(atPath: storeURL.path))
    }

    @Test func asyncLookupPreservesThePersistentSeventyTwoHourBoundary() async throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let storeURL = f.root.appendingPathComponent("boundary-gate.json")
        let gate = SubscriptionRequestGate(storeURL: storeURL)
        let url = URL(string: "https://example.invalid/subscription")!
        let observed = Date(timeIntervalSince1970: 1_800_000_000)
        let available = try await gate.nextAllowedDateAsync(for: url, observedAttempt: observed, now: observed)
        #expect(available == observed.addingTimeInterval(72 * 3600))
        #expect(throws: SubscriptionCooldown.self) { try gate.reserve(url, now: observed.addingTimeInterval(71 * 3600)) }
        try gate.reserve(url, now: observed.addingTimeInterval(72 * 3600))
        #expect(try gate.nextAllowedDate(for: url, now: observed.addingTimeInterval(72 * 3600)) == observed.addingTimeInterval(144 * 3600))
    }

    @Test func heldGateStillReturnsTheExistingCooldownAfterRelease() async throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let storeURL = f.root.appendingPathComponent("held-gate.json")
        let gate = SubscriptionRequestGate(storeURL: storeURL)
        let url = URL(string: "https://example.invalid/subscription")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try gate.reserve(url, now: now)
        let held = try GateTestLock(url: storeURL)
        defer { held.release() }
        var completed = false
        let check = Task {
            let result = try await gate.nextAllowedDateAsync(for: url, now: now)
            completed = true
            return result
        }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))
        #expect(held.isHeld && !completed)
        held.release()
        #expect(try await check.value == now.addingTimeInterval(72 * 3600))
        #expect(throws: SubscriptionCooldown.self) { try gate.reserve(url, now: now.addingTimeInterval(71 * 3600)) }
    }

    @Test func initializationLoadsAnExistingCooldown() async throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open()
        let gate = SubscriptionRequestGate(storeURL: f.root.appendingPathComponent("initial-gate.json"))
        let url = URL(string: "https://a.example/old-secret")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try gate.reserve(url, now: now)
        var services = f.vault.services
        services.now = { now }
        services.nextSubscriptionRequest = { try await gate.nextAllowedDateAsync(for: $0, observedAttempt: $1, now: now) }
        let model = MonitorModel(profileID: f.first.historyID, credentialAccount: f.first.credentialAccount,
                                 defaults: f.defaults, services: services, historyDirectory: f.root,
                                 startAutomatically: false, repository: store, airportID: f.first.id)
        defer { model.stop() }
        try await waitUntil { model.requestAvailableAt != nil }
        #expect(model.requestAvailableAt == now.addingTimeInterval(72 * 3600))
    }

    @Test func stoppedRefreshCancelsItsPendingGateCheck() async throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open()
        let storeURL = f.root.appendingPathComponent("refresh-gate.json")
        let gate = SubscriptionRequestGate(storeURL: storeURL)
        var services = f.vault.services
        var checks = 0
        services.nextSubscriptionRequest = { url, attempt in
            checks += 1
            if checks == 1 { return nil }
            return try await gate.nextAllowedDateAsync(for: url, observedAttempt: attempt)
        }
        let model = MonitorModel(profileID: f.first.historyID, credentialAccount: f.first.credentialAccount,
                                 defaults: f.defaults, services: services, historyDirectory: f.root,
                                 startAutomatically: false, repository: store, airportID: f.first.id)
        defer { model.stop() }
        try await waitUntil { checks == 1 }
        let held = try GateTestLock(url: storeURL)
        let watchdog = DispatchWorkItem { held.release() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: watchdog)
        defer { watchdog.cancel(); held.release() }
        let before = model.ledger.samples.map(\.id)
        let request = Task { await model.refresh() }
        try await waitUntil { checks == 2 }
        #expect(model.busy)
        model.stop()
        await request.value
        #expect(held.isHeld, "Stopped refresh waited for the gate lock")
        #expect(!model.busy && model.ledger.samples.map(\.id) == before)
        #expect(f.vault.fetches == 0 && model.error == nil)
        #expect(!FileManager.default.fileExists(atPath: storeURL.path))
    }

    @Test func corruptGateStopsRefreshWithoutChangingHistory() async throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open()
        let storeURL = f.root.appendingPathComponent("corrupt-gate.json")
        let damaged = Data("broken".utf8)
        try damaged.write(to: storeURL)
        let gate = SubscriptionRequestGate(storeURL: storeURL)
        var services = f.vault.services
        services.nextSubscriptionRequest = { try await gate.nextAllowedDateAsync(for: $0, observedAttempt: $1) }
        let model = MonitorModel(profileID: f.first.historyID, credentialAccount: f.first.credentialAccount,
                                 defaults: f.defaults, services: services, historyDirectory: f.root,
                                 startAutomatically: false, repository: store, airportID: f.first.id)
        defer { model.stop() }
        let before = model.ledger.samples.map(\.id)
        await model.refresh()
        #expect(model.storageBlocked && model.error != nil)
        #expect(model.ledger.samples.map(\.id) == before && f.vault.fetches == 0)
        #expect(try Data(contentsOf: storeURL) == damaged)
    }

    @Test(arguments: [false, true])
    func remindersWaitForInitialGateFailure(invalidate: Bool) async throws {
        let f = try ReminderIntegrationFixture(); defer { f.cleanup() }
        try f.open(); try f.seed()
        let storeURL = f.original.root.appendingPathComponent("reminder-gate.json")
        try Data("broken".utf8).write(to: storeURL)
        let gate = SubscriptionRequestGate(storeURL: storeURL)
        let held = try GateTestLock(url: storeURL)
        let watchdog = DispatchWorkItem { held.release() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: watchdog)
        defer { watchdog.cancel(); held.release() }
        var services = f.services
        var checks = 0
        services.nextSubscriptionRequest = { url, attempt in
            checks += 1
            return try await gate.nextAllowedDateAsync(for: url, observedAttempt: attempt, now: f.now)
        }
        let source = try f.source()
        let model = MonitorModel(profileID: source.id, credentialAccount: f.original.first.credentialAccount,
                                 defaults: f.original.defaults, services: services, historyDirectory: f.original.root,
                                 startAutomatically: false, repository: f.store, airportID: f.original.first.id)
        defer { model.stop() }
        try await waitUntil { checks == 1 }
        if invalidate {
            model.setLifecycle(enabled: false, archived: false, refreshOnResume: false)
            model.setLifecycle(enabled: true, archived: false, refreshOnResume: false)
            try await waitUntil { checks >= 2 }
        }
        let evaluation = Task { await model.evaluateReminders() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(held.isHeld && f.sends == 0)
        held.release()
        await evaluation.value
        #expect(model.storageBlocked && f.sends == 0)
    }

    @Test func cancellingOneWaiterDoesNotLoseAnotherReminderEvaluation() async throws {
        let f = try ReminderIntegrationFixture(); defer { f.cleanup() }
        try f.open(); try f.seed()
        let storeURL = f.original.root.appendingPathComponent("shared-reminder-gate.json")
        let gate = SubscriptionRequestGate(storeURL: storeURL)
        let held = try GateTestLock(url: storeURL)
        let watchdog = DispatchWorkItem { held.release() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: watchdog)
        defer { watchdog.cancel(); held.release() }
        var services = f.services
        var checks = 0
        services.nextSubscriptionRequest = { url, attempt in
            checks += 1
            return try await gate.nextAllowedDateAsync(for: url, observedAttempt: attempt, now: f.now)
        }
        let source = try f.source()
        let model = MonitorModel(profileID: source.id, credentialAccount: f.original.first.credentialAccount,
                                 defaults: f.original.defaults, services: services, historyDirectory: f.original.root,
                                 startAutomatically: false, repository: f.store, airportID: f.original.first.id)
        defer { model.stop() }
        try await waitUntil { checks == 1 }
        var firstStarted = false, secondStarted = false
        let first = Task { firstStarted = true; await model.evaluateReminders() }
        let second = Task { secondStarted = true; await model.evaluateReminders() }
        try await waitUntil { firstStarted && secondStarted }
        first.cancel(); await first.value
        try await waitUntil { checks >= 2 }
        #expect(held.isHeld && f.sends == 0)
        held.release()
        await second.value
        #expect(f.sends == 1)
    }

    @Test func staleGateCompletionCannotOverwriteANewerRefresh() async throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open(), checks = DeferredGateChecks()
        defer { checks.cancelRemaining() }
        var services = f.vault.services
        services.nextSubscriptionRequest = { _, _ in try await checks.check() }
        let model = MonitorModel(profileID: f.first.historyID, credentialAccount: f.first.credentialAccount,
                                 defaults: f.defaults, services: services, historyDirectory: f.root,
                                 startAutomatically: false, repository: store, airportID: f.first.id)
        defer { model.stop() }
        try await waitUntil { checks.calls == 1 }
        let old = Task { await model.refresh() }
        try await waitUntil { checks.calls == 2 }
        model.invalidateRequests()
        let current = Task { await model.refresh() }
        try await waitUntil { checks.calls == 3 }
        checks.finish(0, value: Date().addingTimeInterval(72 * 3600))
        await old.value
        #expect(model.busy && model.requestAvailableAt == nil && model.error == nil)
        checks.finish(1, value: nil)
        await current.value
        #expect(!model.busy && f.vault.fetches == 1 && model.error == nil)
    }

    @Test func staleInitialGateCompletionCannotOverwriteANewerRead() async throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open()
        var continuation: CheckedContinuation<Date?, Error>?
        defer { continuation?.resume(throwing: CancellationError()) }
        var calls = 0, initialFinished = false
        var services = f.vault.services
        services.nextSubscriptionRequest = { _, _ in
            calls += 1
            if calls == 1 {
                let result: Date? = try await withCheckedThrowingContinuation { continuation = $0 }
                initialFinished = true
                return result
            }
            return nil
        }
        let model = MonitorModel(profileID: f.first.historyID, credentialAccount: f.first.credentialAccount,
                                 defaults: f.defaults, services: services, historyDirectory: f.root,
                                 startAutomatically: false, repository: store, airportID: f.first.id)
        defer { model.stop() }
        try await waitUntil { continuation != nil }
        model.invalidateRequests()
        await model.refresh()
        #expect(f.vault.fetches == 1 && model.requestAvailableAt == nil)
        let pending = try #require(continuation)
        continuation = nil
        pending.resume(returning: Date().addingTimeInterval(72 * 3600))
        try await waitUntil { initialFinished }
        await Task.yield()
        #expect(model.requestAvailableAt == nil && model.error == nil)
    }

    @Test func previewReservationDoesNotBlockTheMainActor() async throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let storeURL = f.root.appendingPathComponent("preview-gate.json")
        let gate = SubscriptionRequestGate(storeURL: storeURL)
        let held = try GateTestLock(url: storeURL)
        let watchdog = DispatchWorkItem { held.release() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: watchdog)
        defer { watchdog.cancel(); held.release() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GateNoNetworkProtocol.self]
        let client = SubscriptionClient(configuration: config, gate: gate)
        let before = GateNoNetworkProtocol.startCount
        var entered = false
        let preview = SubscriptionPreview(fetch: { url in
            entered = true
            return try await client.fetch(url)
        })
        preview.setInput("https://example.invalid/subscription")
        let request = Task { await preview.read() }
        try await waitUntil { entered }
        try await Task.sleep(for: .milliseconds(50))
        #expect(held.isHeld, "Preview reservation blocked the main actor")
        preview.cancel()
        held.release()
        await request.value
        #expect(preview.state == .cancelled && GateNoNetworkProtocol.startCount == before)
    }
}
