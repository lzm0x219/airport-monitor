import Foundation
import Darwin
import Testing
import TrafficCore
@testable import NativeModels

@Suite @MainActor
struct MultiInstanceTests {
    @MainActor final class Fixture {
        let original: NativeRepositoryTests.Fixture
        let fetches = WorkspaceLifecycleTests.Fetches()
        let gate: SubscriptionRequestGate
        var now = Date(timeIntervalSince1970: 1_792_497_600 + 30 * 86400)
        var reads = 0
        var sends = 0
        var hosts: [String] = []
        var delayed = false
        var first: AirportWorkspace!
        var second: AirportWorkspace!

        init() throws {
            original = try NativeRepositoryTests.Fixture()
            gate = SubscriptionRequestGate(storeURL: original.root.appendingPathComponent("multi-instance-gate.json"))
            first = open()
            second = open()
        }

        func open() -> AirportWorkspace {
            var services = original.vault.services
            services.now = { self.now }
            services.nextSubscriptionRequest = { try self.gate.nextAllowedDate(for: $0, observedAttempt: $1, now: self.now) }
            services.fetch = { url in
                try self.gate.reserve(url, now: self.now)
                self.reads += 1
                self.hosts.append(url.host ?? "")
                if self.delayed { return try await self.fetches.fetch(url) }
                return try Subscription(upload: 120, download: 500, total: 10000)
            }
            services.notificationAuthorizationStatus = { .denied }
            services.requestNotificationAuthorization = { false }
            services.reminderServices = ReminderServices(authorizationStatus: { .denied },
                send: { _, _, _ in self.sends += 1 }, queryAcceptance: { _ in .unknown })
            return AirportWorkspace(defaults: original.defaults, historyDirectory: original.root,
                                    services: services, startAutomatically: false)
        }

        var profile: AirportProfile { first.profiles[0] }
        var secondModel: MonitorModel { second.model(for: second.profiles[0]) }
        func renameFirst() async {
            let model = first.model(for: profile)
            #expect(await first.save(profile: profile, name: "其他实例的名称", plan: profile.plan,
                subscription: "", reset: model.resetRule, threshold: model.thresholdGB))
        }
        func cleanup() {
            fetches.finish()
            for workspace in [first, second].compactMap({ $0 }) {
                workspace.profiles.forEach { workspace.model(for: $0).stop() }
            }
            original.cleanup()
        }
    }

    @Test func earlierExternalChangeDoesNotConsumeAReadWithoutSavingIt() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let count = try #require(f.first.repository?.source(for: f.profile.id)).ledger.samples.count
        await f.renameFirst()
        await f.secondModel.refresh()
        let reopened = try f.original.open()
        #expect(f.reads == 1 && f.secondModel.error == nil)
        #expect(reopened.source(for: f.profile.id)?.ledger.samples.count == count + 1)
        #expect(reopened.snapshot.catalog.profiles[0].name == "其他实例的名称")
        #expect(f.second.profiles[0].name == "其他实例的名称")
        await f.secondModel.refresh()
        #expect(f.reads == 1 && f.secondModel.requestAvailableAt == f.now.addingTimeInterval(72 * 3600))
        #expect(f.sends == 0)
        try f.original.assertOriginals()
    }

    @Test func unrelatedChangeDuringReadPreservesBothChanges() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let count = try #require(f.first.repository?.source(for: f.profile.id)).ledger.samples.count
        f.delayed = true
        let request = Task { await f.secondModel.refresh() }
        try await f.fetches.waitFor(1)
        await f.renameFirst()
        try f.fetches.succeed(0); await request.value
        let reopened = try f.original.open()
        #expect(f.reads == 1 && f.secondModel.error == nil)
        #expect(reopened.source(for: f.profile.id)?.ledger.samples.count == count + 1)
        #expect(reopened.snapshot.catalog.profiles[0].name == "其他实例的名称")
        #expect(f.second.profiles[0].name == "其他实例的名称")
        #expect(f.sends == 0)
        try f.original.assertOriginals()
    }

    @Test func anotherAirportAddedDuringReadBecomesAvailableWithoutLosingTheReading() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let count = try #require(f.first.repository?.source(for: f.profile.id)).ledger.samples.count
        f.delayed = true
        let request = Task { await f.secondModel.refresh() }
        try await f.fetches.waitFor(1)
        let added = try #require(f.first.repository).saveAirport(profile: nil, name: "新增机场", plan: "",
            subscription: "https://added.example/subscription", reset: ResetRule(), threshold: 10)
        try f.fetches.succeed(0); await request.value
        let reopened = try f.original.open()
        #expect(reopened.source(for: f.profile.id)?.ledger.samples.count == count + 1)
        #expect(f.second.profiles.contains(where: { $0.id == added.id }))
        #expect(f.second.model(for: added).currentProfileID == added.historyID)
        #expect(f.reads == 1 && f.sends == 0)
        try f.original.assertOriginals()
    }

    @Test func changedSourceDuringReadCannotReceiveTheOldSourceResult() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let oldID = f.profile.historyID
        let count = try #require(f.first.repository?.source(for: f.profile.id)).ledger.samples.count
        f.delayed = true
        let request = Task { await f.secondModel.refresh() }
        try await f.fetches.waitFor(1)
        let model = f.first.model(for: f.profile)
        let replacement = try #require(f.first.repository).saveAirport(profile: f.profile,
            name: "新来源", plan: f.profile.plan, subscription: "https://replacement.example/subscription",
            reset: model.resetRule, threshold: model.thresholdGB, change: .newSource)
        try f.fetches.succeed(0); await request.value
        let reopened = try f.original.open()
        #expect(reopened.source(for: f.profile.id)?.id == replacement.historyID)
        #expect(reopened.source(for: f.profile.id)?.ledger.samples.isEmpty == true)
        #expect(reopened.history(for: f.profile.id).first(where: { $0.id == oldID })?.ledger.samples.count == count)
        #expect(f.secondModel.currentProfileID == replacement.historyID)
        #expect(f.reads == 1 && f.sends == 0)
        try f.original.assertOriginals()
    }

    @Test func changedSourceBeforeReadUsesTheNewCredential() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let oldID = f.profile.historyID
        let model = f.first.model(for: f.profile)
        let replacement = try #require(f.first.repository).saveAirport(profile: f.profile,
            name: "新来源", plan: f.profile.plan, subscription: "https://replacement.example/subscription",
            reset: model.resetRule, threshold: model.thresholdGB, change: .newSource)
        await f.secondModel.refresh()
        let reopened = try f.original.open()
        #expect(f.hosts == ["replacement.example"])
        #expect(f.secondModel.currentProfileID == replacement.historyID)
        #expect(reopened.source(for: f.profile.id)?.ledger.samples.count == 1)
        #expect(reopened.history(for: f.profile.id).contains(where: { $0.id == oldID }))
        #expect(f.sends == 0)
        try f.original.assertOriginals()
    }

    @Test func externallyArchivedAirportDoesNotStartAnotherRead() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        #expect(f.first.archive(f.profile, archived: true))
        await f.secondModel.refresh()
        #expect(f.second.profiles[0].archived)
        #expect(f.reads == 0 && f.sends == 0)
        try f.original.assertOriginals()
    }

    @Test(arguments: ["pause", "archive", "pause-resume"])
    func lifecycleChangeDuringReadRejectsTheOldResult(change: String) async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let count = try #require(f.first.repository?.source(for: f.profile.id)).ledger.samples.count
        f.delayed = true
        let request = Task { await f.secondModel.refresh(purpose: .automatic) }
        try await f.fetches.waitFor(1)
        switch change {
        case "archive": #expect(f.first.archive(f.profile, archived: true))
        case "pause-resume":
            f.first.setEnabled(f.profile, false)
            f.first.setEnabled(f.profile, true)
        default: f.first.setEnabled(f.profile, false)
        }
        try f.fetches.succeed(0); await request.value
        let reopened = try f.original.open()
        #expect(reopened.source(for: f.profile.id)?.ledger.samples.count == count)
        #expect(f.second.profiles[0].enabled == f.first.profiles[0].enabled)
        #expect(f.second.profiles[0].archived == f.first.profiles[0].archived)
        #expect(f.reads == 1 && f.sends == 0)
        try f.original.assertOriginals()
    }

    @Test(arguments: ["reset", "credential"])
    func changedReadContextDuringReadRejectsTheOldResult(change: String) async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let count = try #require(f.first.repository?.source(for: f.profile.id)).ledger.samples.count
        f.delayed = true
        let request = Task { await f.secondModel.refresh() }
        try await f.fetches.waitFor(1)
        let model = f.first.model(for: f.profile)
        var reset = model.resetRule
        if change == "reset" { reset.kind = .monthly; reset.day = 12 }
        _ = try #require(f.first.repository).saveAirport(profile: f.profile, name: f.profile.name,
            plan: f.profile.plan, subscription: change == "credential" ? "https://other.example/new" : "",
            reset: reset, threshold: model.thresholdGB)
        try f.fetches.succeed(0); await request.value
        let reopened = try f.original.open()
        #expect(reopened.source(for: f.profile.id)?.ledger.samples.count == count)
        #expect(f.secondModel.resetRule == reset)
        #expect(f.reads == 1 && f.sends == 0)
        try f.original.assertOriginals()
    }

    @Test func previouslySynchronizedExternalRuleChangeStillInvalidatesTheRead() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let count = try #require(f.first.repository?.source(for: f.profile.id)).ledger.samples.count
        let secondStore = try #require(f.second.repository)
        // Exercise the repository guard independently of workspace callbacks.
        secondStore.onExternalChange = nil
        f.delayed = true
        let request = Task { await f.secondModel.refresh() }
        try await f.fetches.waitFor(1)
        let model = f.first.model(for: f.profile)
        var reset = model.resetRule; reset.kind = .monthly; reset.day = 12
        _ = try #require(f.first.repository).saveAirport(profile: f.profile, name: f.profile.name,
            plan: f.profile.plan, subscription: "", reset: reset, threshold: model.thresholdGB)
        try secondStore.synchronize()
        try f.fetches.succeed(0); await request.value
        let reopened = try f.original.open()
        #expect(reopened.source(for: f.profile.id)?.ledger.samples.count == count)
        #expect(reopened.source(for: f.profile.id)?.resetRule == reset)
        #expect(f.reads == 1 && f.sends == 0)
        try f.original.assertOriginals()
    }

    @Test func localRuleEditAndUnrelatedExternalEditBothSurviveTheRead() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let count = try #require(f.first.repository?.source(for: f.profile.id)).ledger.samples.count
        f.delayed = true
        let request = Task { await f.secondModel.refresh() }
        try await f.fetches.waitFor(1)
        var reset = f.secondModel.resetRule; reset.kind = .monthly; reset.day = 12
        await f.secondModel.savePreferences(interval: 4320, reminders: false, threshold: 42, reset: reset)
        try #require(f.first.repository).synchronize()
        await f.renameFirst()
        try f.fetches.succeed(0); await request.value
        let reopened = try f.original.open()
        #expect(reopened.snapshot.catalog.profiles[0].name == "其他实例的名称")
        #expect(reopened.source(for: f.profile.id)?.resetRule == reset)
        #expect(reopened.source(for: f.profile.id)?.threshold == 42)
        #expect(reopened.source(for: f.profile.id)?.ledger.samples.count == count + 1)
        #expect(f.secondModel.error == nil && f.reads == 1 && f.sends == 0)
        try f.original.assertOriginals()
    }

    @Test func reminderChangeDuringReadIsPreservedWithTheNewReading() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let count = try #require(f.first.repository?.source(for: f.profile.id)).ledger.samples.count
        f.delayed = true
        let request = Task { await f.secondModel.refresh() }
        try await f.fetches.waitFor(1)
        let firstStore = try #require(f.first.repository)
        var source = try #require(firstStore.source(for: f.profile.id))
        let preferences = ReminderPreferences(lowEnabled: false, forecastEnabled: false, expiryEnabled: false)
        source.reminderPreferences = preferences
        try firstStore.updateSource(source)
        try f.fetches.succeed(0); await request.value
        let reopened = try f.original.open()
        #expect(reopened.source(for: f.profile.id)?.reminderPreferences == preferences)
        #expect(reopened.source(for: f.profile.id)?.ledger.samples.count == count + 1)
        #expect(f.secondModel.error == nil && f.reads == 1 && f.sends == 0)
        try f.original.assertOriginals()
    }

    @Test func anotherReadingDuringReadIsNeverOverwritten() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.delayed = true
        let request = Task { await f.secondModel.refresh() }
        try await f.fetches.waitFor(1)
        let firstStore = try #require(f.first.repository)
        var source = try #require(firstStore.source(for: f.profile.id))
        try source.ledger.append(Subscription(upload: 120, download: 600, total: 10000),
                                 at: f.now.addingTimeInterval(-60))
        let newID = try #require(source.ledger.samples.last?.id)
        try firstStore.updateSource(source)
        try f.fetches.succeed(0); await request.value
        let reopened = try f.original.open()
        #expect(reopened.source(for: f.profile.id)?.ledger.samples.last?.id == newID)
        #expect(f.secondModel.latest?.id == newID)
        #expect(f.reads == 1 && f.sends == 0)
        try f.original.assertOriginals()
    }

    @Test func pauseAndResumeStillInvalidatesWhenVerificationWasAlreadyPending() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let firstStore = try #require(f.first.repository)
        var source = try #require(firstStore.source(for: f.profile.id))
        source.needsVerification = true
        try firstStore.updateSource(source)
        try #require(f.second.repository).synchronize()
        let count = source.ledger.samples.count
        f.delayed = true
        let request = Task { await f.secondModel.refresh(purpose: .automatic) }
        try await f.fetches.waitFor(1)
        f.first.setEnabled(f.profile, false)
        f.first.setEnabled(f.profile, true)
        try f.fetches.succeed(0); await request.value
        #expect(try f.original.open().source(for: f.profile.id)?.ledger.samples.count == count)
        #expect(f.secondModel.linkVerificationPending)
        #expect(f.reads == 1 && f.sends == 0)
        try f.original.assertOriginals()
    }

    @Test func completedReadWaitsForAnotherProcessWithoutSendingAgain() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let count = try #require(f.first.repository?.source(for: f.profile.id)).ledger.samples.count
        f.delayed = true
        let request = Task { await f.secondModel.refresh() }
        try await f.fetches.waitFor(1)
        let lockPath = try #require(f.first.repository).directory.appendingPathComponent("store.lock").path
        let holder = Process(), ready = Pipe()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        holder.arguments = ["swift", "-e", """
            import Darwin
            let fd = open(CommandLine.arguments[1], O_RDWR)
            guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { _exit(2) }
            var marker: UInt8 = 1
            _ = write(STDOUT_FILENO, &marker, 1)
            usleep(700_000)
            flock(fd, LOCK_UN); close(fd)
            """, lockPath]
        holder.standardOutput = ready
        holder.standardError = FileHandle.nullDevice
        try holder.run()
        defer { if holder.isRunning { holder.terminate(); holder.waitUntilExit() } }
        try #require(ready.fileHandleForReading.read(upToCount: 1) == Data([1]))
        try f.fetches.succeed(0)
        try await Task.sleep(for: .milliseconds(150))
        #expect(f.secondModel.busy && holder.isRunning)
        await request.value
        holder.waitUntilExit()
        #expect(holder.terminationStatus == 0 && f.reads == 1 && f.secondModel.error == nil)
        #expect(try f.original.open().source(for: f.profile.id)?.ledger.samples.count == count + 1)
        #expect(f.sends == 0)
        try f.original.assertOriginals()
    }

    @Test func readWaitsForAnotherWriterBeforeSendingOnlyOnce() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let count = try #require(f.first.repository?.source(for: f.profile.id)).ledger.samples.count
        let path = try #require(f.first.repository).directory.appendingPathComponent("store.lock").path
        let descriptor = open(path, O_RDWR)
        try #require(descriptor >= 0)
        try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        var firstFinished = false
        let first = Task { await f.secondModel.refresh(); firstFinished = true }
        try await Task.sleep(for: .milliseconds(150))
        let duplicate = Task { await f.secondModel.refresh() }
        #expect(f.reads == 0 && !firstFinished)
        flock(descriptor, LOCK_UN); close(descriptor)
        await first.value; await duplicate.value
        #expect(f.reads == 1 && f.secondModel.error == nil)
        #expect(try f.original.open().source(for: f.profile.id)?.ledger.samples.count == count + 1)
        #expect(f.sends == 0)
        try f.original.assertOriginals()
    }

    @Test func stoppingAPreflightWaitDoesNotCancelTheNextRead() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let path = try #require(f.first.repository).directory.appendingPathComponent("store.lock").path
        let descriptor = open(path, O_RDWR)
        try #require(descriptor >= 0)
        try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        let old = Task { await f.secondModel.refresh() }
        try await Task.sleep(for: .milliseconds(150))
        f.secondModel.stop()
        let next = Task { await f.secondModel.refresh() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(f.reads == 0)
        flock(descriptor, LOCK_UN); close(descriptor)
        await old.value; await next.value
        #expect(f.reads == 1 && f.secondModel.error == nil)
        #expect(f.sends == 0)
        try f.original.assertOriginals()
    }

    @Test func stoppingWhileWaitingForTheStoreDiscardsTheResult() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let count = try #require(f.first.repository?.source(for: f.profile.id)).ledger.samples.count
        f.delayed = true
        let request = Task { await f.secondModel.refresh() }
        try await f.fetches.waitFor(1)
        let path = try #require(f.first.repository).directory.appendingPathComponent("store.lock").path
        let descriptor = open(path, O_RDWR)
        try #require(descriptor >= 0)
        try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        try f.fetches.succeed(0)
        try await Task.sleep(for: .milliseconds(150))
        #expect(f.secondModel.busy)
        f.secondModel.stop()
        await request.value
        #expect(!f.secondModel.busy && f.secondModel.ledger.samples.count == count)
        #expect(f.reads == 1 && f.sends == 0)
    }

    @Test func olderWriterWithoutReadContextMetadataFailsClosed() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let count = try #require(f.first.repository?.source(for: f.profile.id)).ledger.samples.count
        f.delayed = true
        let request = Task { await f.secondModel.refresh() }
        try await f.fetches.waitFor(1)
        await f.renameFirst()
        let stateURL = try #require(f.first.repository).stateURL
        var snapshot = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        var sources = try #require(snapshot["sources"] as? [[String: Any]])
        for index in sources.indices { sources[index].removeValue(forKey: "readContextRevision") }
        snapshot["sources"] = sources
        try JSONSerialization.data(withJSONObject: snapshot).write(to: stateURL, options: .atomic)
        try f.fetches.succeed(0); await request.value
        let reopened = try f.original.open()
        #expect(reopened.snapshot.catalog.profiles[0].name == "其他实例的名称")
        #expect(reopened.source(for: f.profile.id)?.ledger.samples.count == count)
        #expect(f.second.profiles[0].name == "其他实例的名称")
        #expect(f.reads == 1 && f.sends == 0)
        try f.original.assertOriginals()
    }

    @Test func failedReadDuringAnUnrelatedChangeRetainsTheErrorAndAttempt() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.delayed = true
        let request = Task { await f.secondModel.refresh() }
        try await f.fetches.waitFor(1)
        await f.renameFirst()
        f.fetches.fail(0); await request.value
        let reopened = try f.original.open()
        #expect(f.secondModel.error == TrafficError.network(-1009).localizedDescription)
        #expect(reopened.source(for: f.profile.id)?.syncAttempts.first?.message == f.secondModel.error)
        #expect(reopened.snapshot.catalog.profiles[0].name == "其他实例的名称")
        #expect(f.reads == 1 && f.sends == 0)
        try f.original.assertOriginals()
    }

    @Test func staleEditReloadsOtherChangesBeforeRetry() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let old = f.second.profiles[0]
        let model = f.secondModel
        await f.renameFirst()
        #expect(!(await f.second.save(profile: old, name: "稍后保存", plan: old.plan,
            subscription: "", reset: model.resetRule, threshold: model.thresholdGB)))
        #expect(f.second.profiles[0].name == "其他实例的名称")
        #expect(await f.second.save(profile: f.second.profiles[0], name: "稍后保存", plan: old.plan,
            subscription: "", reset: model.resetRule, threshold: model.thresholdGB))
        #expect(try f.original.open().snapshot.catalog.profiles[0].name == "稍后保存")
        #expect(f.reads == 0 && f.sends == 0)
        try f.original.assertOriginals()
    }

    @Test func previewSurvivesExternalCommitAndCanBeConfirmedWithoutAnotherRead() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let preview = f.second.makePreview()
        preview.setInput("https://preview.example/subscription")
        await preview.read()
        #expect(preview.confirmation != nil && f.reads == 1)
        await f.renameFirst()
        #expect(await f.second.confirmPreview(preview, name: "预览机场") == nil)
        #expect(preview.confirmation != nil && f.second.profiles[0].name == "其他实例的名称")
        let id = try #require(await f.second.confirmPreview(preview, name: "预览机场"))
        let reopened = try f.original.open()
        #expect(reopened.source(for: id)?.ledger.samples.count == 1)
        #expect(reopened.snapshot.catalog.profiles[0].name == "其他实例的名称")
        #expect(f.reads == 1 && f.sends == 0)
        try f.original.assertOriginals()
    }
}
