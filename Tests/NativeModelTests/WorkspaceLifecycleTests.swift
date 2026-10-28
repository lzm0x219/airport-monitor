import Testing
import Foundation
import TrafficCore
@testable import NativeModels

@Suite @MainActor
struct WorkspaceLifecycleTests {
    @MainActor final class Fetches {
        var requests: [CheckedContinuation<Subscription, any Error>] = []
        var resolved = Set<Int>()
        func fetch(_ url: URL) async throws -> Subscription {
            try await withCheckedThrowingContinuation { requests.append($0) }
        }
        func succeed(_ index: Int, used: UInt64 = 500) throws {
            guard resolved.insert(index).inserted else { return }
            requests[index].resume(returning: try Subscription(upload: 120, download: used, total: 10000))
        }
        func fail(_ index: Int) {
            guard resolved.insert(index).inserted else { return }
            requests[index].resume(throwing: TrafficError.network(-1009))
        }
        func finish() { for index in requests.indices where !resolved.contains(index) { fail(index) } }
        func waitFor(_ count: Int) async throws {
            for _ in 0..<1000 {
                if requests.count >= count { return }
                try await Task.sleep(for: .milliseconds(1))
            }
            Issue.record("Expected \(count) requests, observed \(requests.count)")
            throw TrafficError.storage
        }
    }

    @MainActor final class Fixture {
        let original: NativeRepositoryTests.Fixture
        let fetches = Fetches()
        var failCommit = false
        var workspace: AirportWorkspace!
        init() throws {
            original = try NativeRepositoryTests.Fixture()
            // Stable order: main, paused backup, running backup.
            original.catalog.profiles[1].archived = false
            let third = AirportProfile(id: UUID(), historyID: UUID().uuidString, credentialAccount: "legacy-c",
                name: "第三机场", plan: "保留套餐", enabled: true, archived: false)
            original.catalog.profiles.append(third)
            original.vault.credentials[third.credentialAccount] = "https://c.example/subscription"
            try original.original.write(to: original.root.appendingPathComponent("\(third.historyID).json"))
            original.defaults.set(try JSONEncoder().encode(original.catalog), forKey: "airportCatalog.v1")
            var services = original.vault.services
            services.fetch = { [fetches] in try await fetches.fetch($0) }
            services.requestNotificationAuthorization = { false }
            workspace = AirportWorkspace(defaults: original.defaults, historyDirectory: original.root,
                services: services, startAutomatically: false, checkpoint: { [weak self] point in
                    if self?.failCommit == true && point == .beforePublish { throw TrafficError.storage }
                })
            #expect(!workspace.catalogBlocked)
        }
        func cleanup() {
            for profile in workspace.profiles { workspace.model(for: profile).stop() }
            fetches.finish(); original.cleanup()
        }
        var main: AirportProfile { workspace.profiles[0] }
        var model: MonitorModel { workspace.model(for: main) }
        var store: NativeRepository { workspace.repository! }
        func waitUntilIdle(_ model: MonitorModel) async throws {
            for _ in 0..<1000 {
                if !model.busy { return }
                try await Task.sleep(for: .milliseconds(1))
            }
            Issue.record("Request did not finish"); throw TrafficError.storage
        }
    }

    @Test(arguments: [false, true])
    func pauseInvalidatesLateSuccessAndFailure(lateFailure: Bool) async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let before = try #require(f.store.source(for: f.main.id))
        let request = Task { await f.model.refresh() }
        try await f.fetches.waitFor(1)
        f.workspace.setEnabled(f.main, false)
        #expect(!f.main.enabled && !f.model.busy)
        if lateFailure { f.fetches.fail(0) } else { try f.fetches.succeed(0) }
        await request.value
        let after = try #require(f.store.source(for: f.main.id))
        #expect(after.ledger.samples.map(\.id) == before.ledger.samples.map(\.id))
        #expect(after.syncAttempts.map(\.id) == before.syncAttempts.map(\.id))
        #expect(f.model.error == nil)
        #expect(after.needsVerification)
    }

    @Test func rapidResumeRejectsEarlierRequestWithoutClearingNewBusyState() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let before = f.model.ledger.samples.count
        let request = Task { await f.model.refresh() }
        try await f.fetches.waitFor(1)
        f.workspace.setEnabled(f.main, false)
        f.workspace.setEnabled(f.main, true)
        try await f.fetches.waitFor(2)
        f.fetches.fail(0); await request.value
        #expect(f.model.busy && f.model.error == nil)
        try f.fetches.succeed(1)
        try await f.waitUntilIdle(f.model)
        #expect(f.model.ledger.samples.count == before + 1)
        #expect(f.model.syncAttempts.count == 1)
    }

    @Test func archiveCancelsRequestAndRestoreFirstReadCanFailThenRetry() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let before = f.model.ledger.samples.map(\.id)
        let old = Task { await f.model.refresh() }
        try await f.fetches.waitFor(1)
        f.workspace.archive(f.main, archived: true)
        #expect(f.main.archived && f.main.enabled)
        #expect(f.workspace.menuAirport == f.workspace.profiles[2].id)
        let count = f.fetches.requests.count
        await f.model.refresh()
        #expect(f.fetches.requests.count == count)
        f.workspace.archive(f.main, archived: false)
        try await f.fetches.waitFor(2)
        try f.fetches.succeed(0); await old.value
        #expect(f.model.busy && f.model.ledger.samples.map(\.id) == before)
        f.fetches.fail(1); try await f.waitUntilIdle(f.model)
        #expect(f.model.error != nil)
        #expect(f.store.source(for: f.main.id)?.needsVerification == true)
        #expect(f.model.ledger.samples.map(\.id) == before)
        let retry = Task { await f.model.refresh() }
        try await f.fetches.waitFor(3)
        try f.fetches.succeed(2); await retry.value
        #expect(f.model.error == nil)
        #expect(f.model.ledger.samples.count == before.count + 1)
        let source = try #require(f.store.source(for: f.main.id))
        #expect(!source.needsVerification)
        #expect(source.gaps.count == 1 && source.gaps[0].restoredAt != nil)
        #expect(source.syncAttempts.count == 2)
        #expect(f.workspace.menuAirport == f.workspace.profiles[2].id)
        try f.original.assertOriginals()
    }

    @Test func pauseResumePauseInvalidatesBothUncooperativeRequests() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let before = try #require(f.store.source(for: f.main.id))
        let first = Task { await f.model.refresh() }
        try await f.fetches.waitFor(1)
        f.workspace.setEnabled(f.main, false)
        f.workspace.setEnabled(f.main, true)
        try await f.fetches.waitFor(2)
        f.workspace.setEnabled(f.main, false)
        try f.fetches.succeed(0); await first.value
        f.fetches.fail(1)
        // Let the resumed task consume its late failure.
        for _ in 0..<20 { await Task.yield() }
        let after = try #require(f.store.source(for: f.main.id))
        #expect(!f.model.enabled && !f.model.busy && f.model.error == nil)
        #expect(after.ledger.samples.map(\.id) == before.ledger.samples.map(\.id))
        #expect(after.syncAttempts.map(\.id) == before.syncAttempts.map(\.id))
        #expect(after.needsVerification)
    }

    @Test func refreshAllRechecksQueuedAirportAfterPause() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let all = Task { await f.workspace.refreshAll() }
        try await f.fetches.waitFor(1)
        f.workspace.setEnabled(f.workspace.profiles[2], false)
        try f.fetches.succeed(0); await all.value
        #expect(f.fetches.requests.count == 1)
        #expect(f.workspace.model(for: f.workspace.profiles[2]).syncAttempts.isEmpty)
    }

    @Test func pausedRestoreKeepsPreferenceAndOnlyManualReadRuns() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let paused = f.workspace.profiles[1], model = f.workspace.model(for: paused)
        f.workspace.archive(paused, archived: true)
        f.workspace.archive(paused, archived: false)
        #expect(!f.workspace.profiles[1].enabled && !model.enabled)
        #expect(f.fetches.requests.isEmpty)
        let manual = Task { await model.refresh() }
        try await f.fetches.waitFor(1); try f.fetches.succeed(0); await manual.value
        #expect(!model.enabled && model.latest != nil)
        #expect(f.workspace.menuAirport == f.main.id)
    }

    @Test func primaryHandoffUsesStableUnpausedThenPausedFallbackAndRestoreFillsOnlyEmpty() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let first = f.main, second = f.workspace.profiles[1], third = f.workspace.profiles[2]
        f.workspace.setEnabled(first, false)
        f.workspace.archive(first, archived: true)
        #expect(f.workspace.menuAirport == third.id)
        f.workspace.archive(third, archived: true)
        #expect(f.workspace.menuAirport == second.id)
        f.workspace.archive(second, archived: true)
        #expect(f.workspace.menuAirport == nil)
        f.workspace.archive(second, archived: false)
        #expect(f.workspace.menuAirport == second.id)
        // Keep the restored airport paused to avoid starting asynchronous work.
        f.workspace.archive(first, archived: false)
        #expect(f.workspace.menuAirport == second.id)
    }

    @Test(arguments: [false, true])
    func failedLifecycleCommitLeavesInFlightRequestAndSelectionIntact(archive: Bool) async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let oldBytes = try Data(contentsOf: f.store.stateURL)
        let request = Task { await f.model.refresh() }
        try await f.fetches.waitFor(1)
        f.failCommit = true
        if archive { f.workspace.archive(f.main, archived: true) }
        else { f.workspace.setEnabled(f.main, false) }
        #expect(!f.main.archived && f.main.enabled && f.model.busy)
        #expect(f.workspace.menuAirport == f.main.id)
        #expect(try Data(contentsOf: f.store.stateURL) == oldBytes)
        f.failCommit = false
        try f.fetches.succeed(0); await request.value
        #expect(f.model.error == nil && f.model.syncAttempts.count == 1)
    }

    @Test func duplicateSaveCommitsOnceAndReadFailureDoesNotUndoSavedConfiguration() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let before = f.model.ledger.samples.map(\.id)
        let profile = f.main
        let save = Task { await f.workspace.save(profile: profile, name: "已保存名称", plan: "保留套餐",
            subscription: "https://new.example/subscription", reset: f.model.resetRule, threshold: 8) }
        try await f.fetches.waitFor(1)
        let revision = f.store.snapshot.revision
        let duplicate = await f.workspace.save(profile: profile, name: "已保存名称", plan: "保留套餐",
            subscription: "https://new.example/subscription", reset: f.model.resetRule, threshold: 8)
        #expect(!duplicate && f.store.snapshot.revision == revision)
        f.fetches.fail(0)
        #expect(await save.value)
        #expect(f.main.name == "已保存名称" && f.model.error != nil)
        #expect(f.model.ledger.samples.map(\.id) == before)
        #expect(f.workspace.sourceHistory(for: f.main).count == 1)
        #expect(f.workspace.message?.contains("已保存") == true)
    }

    @Test func failedRestoreDoesNotStartRequestAndRetryClosesTheSameGap() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.workspace.archive(f.main, archived: true)
        let before = try Data(contentsOf: f.store.stateURL)
        f.failCommit = true
        #expect(!f.workspace.archive(f.main, archived: false))
        #expect(f.main.archived && f.fetches.requests.isEmpty)
        #expect(try Data(contentsOf: f.store.stateURL) == before)
        #expect(f.store.source(for: f.main.id)?.gaps.first?.restoredAt == nil)
        f.failCommit = false
        #expect(f.workspace.archive(f.main, archived: false))
        try await f.fetches.waitFor(1)
        try f.fetches.succeed(0); try await f.waitUntilIdle(f.model)
        #expect(f.store.source(for: f.main.id)?.gaps.count == 1)
        #expect(f.store.source(for: f.main.id)?.gaps.first?.restoredAt != nil)
    }

    @Test func globalPreferencesApplyDuringFetchAndIncludeArchivedAirports() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.workspace.archive(f.workspace.profiles[1], archived: true)
        let request = Task { await f.model.refresh() }
        try await f.fetches.waitFor(1)
        await f.workspace.setReminders(true)
        f.workspace.setInterval(30)
        #expect(f.original.defaults.bool(forKey: "remindersEnabled"))
        #expect(f.original.defaults.integer(forKey: "intervalMinutes") == 4320)
        #expect(f.workspace.profiles.allSatisfy { f.workspace.model(for: $0).remindersEnabled })
        #expect(f.workspace.profiles.allSatisfy { f.workspace.model(for: $0).intervalMinutes == 4320 })
        #expect(f.model.busy)
        await f.workspace.setReminders(false)
        #expect(f.workspace.profiles.allSatisfy { !f.workspace.model(for: $0).remindersEnabled })
        try f.fetches.succeed(0); await request.value
        #expect(f.model.error == nil)
    }

    @Test func notificationPreferencePersistsWithoutAnyAirport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EmptyWorkspace-\(UUID())")
        let suite = "EmptyWorkspace.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        var permissionRequests = 0
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let workspace = AirportWorkspace(defaults: defaults, historyDirectory: root,
            services: MonitorServices(readCredential: { _ in nil }, notificationAuthorizationStatus: { .notDetermined },
                requestNotificationAuthorization: { permissionRequests += 1; return false }),
            startAutomatically: false)
        #expect(workspace.profiles.isEmpty && !workspace.catalogBlocked)
        await workspace.setReminders(true)
        #expect(defaults.bool(forKey: "remindersEnabled"))
        #expect(permissionRequests == 1)
        await workspace.setReminders(false)
        #expect(!defaults.bool(forKey: "remindersEnabled"))
    }
}
