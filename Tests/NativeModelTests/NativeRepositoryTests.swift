import Testing
import Foundation
import TrafficCore
@testable import NativeModels

@Suite @MainActor
struct NativeRepositoryTests {
    @Test func migrationRetainsIDsSamplesRulesAndPreferences() throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let beforeDefaults = f.defaults.dictionaryRepresentation()
        let store = try f.open(), source = try #require(store.source(for: f.first.id))
        #expect(store.snapshot.catalog.version == 2)
        #expect(store.snapshot.catalog.profiles.map(\.id) == f.catalog.profiles.map(\.id))
        #expect(source.id == f.first.historyID)
        #expect(source.ledger.samples.map(\.id) == (try JSONDecoder().decode(Ledger.self, from: f.original)).samples.map(\.id))
        #expect(source.ledger.lowBalanceNotified); #expect(source.migratedNotificationAt != nil)
        #expect(source.thresholdMode == .legacyAbsoluteGB); #expect(source.threshold == 7.5)
        #expect(!source.notifyForecast && !source.notifyExpiry); #expect(source.resetRule == f.rule)
        #expect(source.resetRevisions[0].effectiveAt == nil)
        #expect(store.snapshot.catalog.profiles[1].archived && !store.snapshot.catalog.profiles[1].enabled)
        #expect(store.snapshot.migration.samples == 4)
        #expect(NSDictionary(dictionary: beforeDefaults).isEqual(to: f.defaults.dictionaryRepresentation()))
        #expect(f.vault.credentials.count == 2); #expect(f.vault.fetches == 0)
        #expect(try f.open().snapshot.revision == store.snapshot.revision)
        try f.assertOriginals()
    }

    @Test func sameSourceChangePreservesHistoryAndNotificationIdentity() throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open(), before = try #require(store.source(for: f.first.id))
        let saved = try f.change(store)
        let after = try #require(store.source(for: saved.id))
        #expect(saved.id == f.first.id); #expect(saved.credentialAccount == f.first.credentialAccount)
        #expect(after.id == before.id); #expect(after.ledger.samples.map(\.id) == before.ledger.samples.map(\.id))
        #expect(after.ledger.lowBalanceNotified); #expect(after.migratedNotificationAt == before.migratedNotificationAt)
        #expect(after.needsVerification); #expect(store.history(for: saved.id).count == 1)
        #expect(f.vault.credentials[after.credentialReference] == "https://new.example/private-token")
        #expect(try f.open().source(for: saved.id)?.credentialReference == after.credentialReference)
        let contents = try String(contentsOf: store.stateURL, encoding: .utf8)
        #expect(!contents.contains("private-token") && !contents.contains("https://"))
        try f.assertOriginals()
    }

    @Test func newSourceKeepsCompletePreviousSegmentAndStartsEmpty() throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open(), saved = try f.change(store, mode: .newSource)
        let active = try #require(store.source(for: saved.id)), history = store.history(for: saved.id)
        #expect(saved.id == f.first.id && saved.historyID != f.first.historyID)
        #expect(history.count == 2); #expect(history.first?.endedAt != nil)
        #expect(history.first?.ledger.samples.count == 2)
        #expect(active.ledger.samples.isEmpty && !active.ledger.lowBalanceNotified)
        #expect(active.migratedNotificationAt == nil && active.needsVerification)
        #expect(try f.open().history(for: saved.id).count == 2)
        try f.assertOriginals()
    }

    @Test(arguments: [RepositoryCheckpoint.prepared, .credentialStaged, .beforePublish])
    func failedSaveDoesNotPublishPartialChanges(point: RepositoryCheckpoint) throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        var fail = true
        let store = try f.open { if fail && $0 == point { throw TrafficError.storage } }
        let before = try Data(contentsOf: store.stateURL)
        #expect(throws: (any Error).self) { try f.change(store, mode: .newSource) }
        #expect(try Data(contentsOf: store.stateURL) == before)
        #expect(store.snapshot.catalog.profiles[0].name == "主力")
        #expect(f.vault.credentials.count == 2)
        fail = false
        _ = try f.change(store, mode: .newSource)
        #expect(store.history(for: f.first.id).count == 2)
        try f.assertOriginals()
    }

    @Test func partiallyWrittenCredentialFailureRollsBack() throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open(); f.vault.failSave = true
        #expect(throws: (any Error).self) { try f.change(store) }
        #expect(f.vault.credentials.count == 2)
        #expect(store.source(for: f.first.id)?.credentialReference == "legacy-a")
        f.vault.failSave = false; _ = try f.change(store)
        #expect(store.history(for: f.first.id).count == 1)
    }

    @Test(arguments: [RepositoryCheckpoint.prepared, .credentialStaged, .beforePublish, .published, .beforeCleanup])
    func restartRecoversEveryCommitBoundary(point: RepositoryCheckpoint) throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open { if $0 == point { throw RepositoryInterruption.simulatedCrash } }
        #expect(throws: RepositoryInterruption.self) { try f.change(store, mode: .newSource) }
        let reopened = try f.open(), committed = point == .published || point == .beforeCleanup
        #expect(reopened.history(for: f.first.id).count == (committed ? 2 : 1))
        #expect(reopened.snapshot.catalog.profiles[0].name == (committed ? "修改名称" : "主力"))
        #expect(f.vault.credentials.count == (committed ? 3 : 2))
        #expect(!reopened.recoveryPending)
        #expect(try f.open().snapshot.revision == reopened.snapshot.revision)
        try f.assertOriginals()
    }

    @Test(arguments: [RepositoryCheckpoint.migrationPrepared, .migrationPublished])
    func migrationRestartIsIdempotent(point: RepositoryCheckpoint) throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        #expect(throws: RepositoryInterruption.self) { try f.open { if $0 == point { throw RepositoryInterruption.simulatedCrash } } }
        let store = try f.open(), reopened = try f.open()
        #expect(store.snapshot.revision == reopened.snapshot.revision)
        #expect(store.snapshot.sources.count == 2); #expect(store.snapshot.migration.samples == 4)
        try f.assertOriginals()
    }

    @Test func cleanupFailureAfterPublishIsSuccessNotRollback() throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open { if $0 == .beforeCleanup { throw TrafficError.storage } }
        _ = try f.change(store)
        #expect(store.recoveryPending)
        let account = try #require(store.source(for: f.first.id)?.credentialReference)
        #expect(try f.open().source(for: f.first.id)?.credentialReference == account)
        #expect(f.vault.credentials[account] != nil)
    }

    @Test func failedCleanupBlocksUntilRecoveryCanComplete() throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open(); f.vault.failSave = true; f.vault.failDelete = true
        #expect(throws: (any Error).self) { try f.change(store) }
        #expect(store.recoveryPending)
        #expect(throws: (any Error).self) { try f.open() }
        f.vault.failDelete = false; f.vault.failSave = false
        let reopened = try f.open()
        #expect(reopened.source(for: f.first.id)?.credentialReference == "legacy-a")
        #expect(f.vault.credentials.count == 2)
    }

    @Test func orphanHistoryIsReportedWithoutGuessingOwner() throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let name = "40000000-0000-0000-0000-000000000001.json"
        try f.original.write(to: f.root.appendingPathComponent(name))
        let store = try f.open()
        #expect(store.snapshot.sources.count == 2)
        #expect(store.snapshot.migration.files.first(where: { $0.name == name })?.associated == false)
        #expect(store.snapshot.migration.warnings.contains(where: { $0.contains(name) }))
        #expect(try Data(contentsOf: f.root.appendingPathComponent(name)) == f.original)
    }

    @Test(arguments: ["ledger", "catalog", "rule", "sync", "future-ledger", "duplicate-sample"])
    func corruptOrUnsupportedLegacyDataNeverPublishesEmptyState(kind: String) throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let ledgerURL = f.root.appendingPathComponent("\(f.first.historyID).json")
        switch kind {
        case "catalog": f.defaults.set(Data("{}".utf8), forKey: "airportCatalog.v1")
        case "rule": f.defaults.set(Data("broken".utf8), forKey: "resetRule.\(f.first.historyID)")
        case "sync": try Data("broken".utf8).write(to: ledgerURL.appendingPathExtension("sync"))
        case "future-ledger": try Data(String(decoding: f.original, as: UTF8.self).replacingOccurrences(of: "\"version\":1", with: "\"version\":99").utf8).write(to: ledgerURL)
        case "duplicate-sample": try Data(String(decoding: f.original, as: UTF8.self).replacingOccurrences(of: "10000000-0000-0000-0000-000000000002", with: "10000000-0000-0000-0000-000000000001").utf8).write(to: ledgerURL)
        default: try Data("broken".utf8).write(to: ledgerURL)
        }
        let bytes = try Data(contentsOf: ledgerURL)
        #expect(throws: (any Error).self) { try f.open() }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("native-v2/state.json").path))
        #expect(try Data(contentsOf: ledgerURL) == bytes)
    }

    @Test func futureV2VersionDoesNotFallBackToLegacy() throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open()
        var value = store.snapshot; value.version = 99
        let bytes = try JSONEncoder().encode(value); try bytes.write(to: store.stateURL)
        #expect(throws: (any Error).self) { try f.open() }
        #expect(try Data(contentsOf: store.stateURL) == bytes)
    }

    @Test func staleWriterCannotOverwriteAnotherRepositoryCommit() throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let first = try f.open(), stale = try f.open()
        _ = try f.change(first)
        #expect(throws: (any Error).self) { try f.change(stale, mode: .newSource) }
        #expect(try f.open().source(for: f.first.id)?.id == f.first.historyID)
        #expect(f.vault.credentials.count == 3)
    }

    @Test func oldSourceCallbackCannotOverwriteNewSource() throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open(), old = try #require(store.source(for: f.first.id))
        _ = try f.change(store, mode: .newSource)
        #expect(throws: (any Error).self) { try store.updateSource(old) }
        #expect(store.source(for: f.first.id)?.ledger.samples.isEmpty == true)
    }

    @Test func workspaceSaveFailureAndRetryPreserveConfiguration() async throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        var fail = true
        let workspace = AirportWorkspace(defaults: f.defaults, historyDirectory: f.root, services: f.vault.services, startAutomatically: false,
                                         checkpoint: { if fail && $0 == .beforePublish { throw TrafficError.storage } })
        let model = workspace.model(for: f.first)
        #expect(await workspace.save(profile: f.first, name: "草稿", plan: "", subscription: "https://new.example/secret", reset: f.rule, threshold: 5) == false)
        #expect(workspace.profiles[0].name == "主力"); #expect(model.thresholdGB == 7.5)
        #expect(model.ledger.samples.count == 2); #expect(f.vault.fetches == 0)
        fail = false; f.vault.failFetch = true
        #expect(await workspace.save(profile: f.first, name: "已保存", plan: "", subscription: "https://new.example/secret", reset: f.rule, threshold: 5))
        #expect(workspace.profiles[0].name == "已保存"); #expect(model.thresholdGB == 5)
        #expect(model.linkVerificationPending && model.error != nil)
        #expect(model.currentProfileID == f.first.historyID && model.ledger.samples.count == 2)
        f.vault.failFetch = false; await model.refresh()
        #expect(!model.linkVerificationPending && model.error == nil)
        #expect(model.ledger.samples.count == 3)
        #expect(try f.open().source(for: f.first.id)?.ledger.samples.count == 3)
        try f.assertOriginals()
    }

    @Test func legacySingleAirportUsesExistingIdentityWithoutSideEffects() throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        f.defaults.removeObject(forKey: "airportCatalog.v1")
        f.defaults.set(f.first.historyID, forKey: "profileID")
        f.vault.credentials["active-url"] = "https://legacy.example/secret"
        let store = try f.open(), source = try #require(store.snapshot.sources.first)
        #expect(store.snapshot.catalog.profiles.count == 1)
        #expect(source.id == f.first.historyID && source.credentialReference == "active-url")
        #expect(source.ledger.samples.count == 2 && source.resetRule == f.rule)
        #expect(f.vault.fetches == 0)
    }

    @Test func readOnlyDirectoryDuringPublishPreservesOldStateAndCanRecover() throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let directory = f.root.appendingPathComponent("native-v2")
        var fail = true
        let store = try f.open { if fail && $0 == .beforePublish { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path) } }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        let before = try Data(contentsOf: store.stateURL)
        #expect(throws: (any Error).self) { try f.change(store) }
        #expect(try Data(contentsOf: store.stateURL) == before)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        fail = false
        let reopened = try f.open()
        #expect(reopened.source(for: f.first.id)?.credentialReference == "legacy-a")
        _ = try f.change(reopened)
        #expect(reopened.source(for: f.first.id)?.needsVerification == true)
        try f.assertOriginals()
    }

    @Test func migrationRetryRefusesChangedLegacyConfiguration() throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        #expect(throws: RepositoryInterruption.self) { try f.open { if $0 == .migrationPrepared { throw RepositoryInterruption.simulatedCrash } } }
        f.defaults.set(12.0, forKey: "thresholdGB.legacy-a")
        #expect(throws: (any Error).self) { try f.open() }
        #expect(f.defaults.double(forKey: "thresholdGB.legacy-a") == 12.0)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("native-v2/state.json").path))
    }

    @Test(arguments: ["changed", "removed", "orphan"])
    func migrationRetryDoesNotPublishWhenLegacyFilesChange(kind: String) throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        #expect(throws: RepositoryInterruption.self) {
            try f.open { if $0 == .migrationPrepared { throw RepositoryInterruption.simulatedCrash } }
        }
        let directory = f.root.appendingPathComponent("native-v2")
        let candidate = directory.appendingPathComponent("migration-candidate.json")
        let preparedBytes = try Data(contentsOf: candidate)
        let legacy = f.root.appendingPathComponent("\(f.first.historyID).json")
        let changedURL: URL
        switch kind {
        case "changed":
            var ledger = try JSONDecoder().decode(Ledger.self, from: f.original)
            let last = try #require(ledger.samples.last)
            try ledger.append(Subscription(upload: last.subscription.upload, download: last.subscription.download + 1,
                                           total: last.subscription.total), at: last.date.addingTimeInterval(60))
            try JSONEncoder().encode(ledger).write(to: legacy)
            changedURL = legacy
        case "removed":
            try FileManager.default.removeItem(at: legacy)
            changedURL = legacy
        default:
            changedURL = f.root.appendingPathComponent("40000000-0000-0000-0000-000000000001.json")
            try f.original.write(to: changedURL)
        }
        let changedBytes = try? Data(contentsOf: changedURL)

        #expect(throws: (any Error).self) { try f.open() }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("state.json").path))
        #expect(try Data(contentsOf: candidate) == preparedBytes)
        #expect((try? Data(contentsOf: changedURL)) == changedBytes)
    }

    @Test func existingSnapshotDoesNotReadDamagedLegacyInputs() throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open()
        let originalState = try Data(contentsOf: store.stateURL)
        let legacy = f.root.appendingPathComponent("\(f.first.historyID).json")
        let damaged = Data("damaged-legacy".utf8)
        try damaged.write(to: legacy)
        f.defaults.set(Data("invalid-catalog".utf8), forKey: "airportCatalog.v1")
        var services = f.vault.services
        services.readCredential = { _ in throw TrafficError.storage }

        let reopened = try NativeRepository(root: f.root, defaults: f.defaults, services: services)
        #expect(reopened.source(for: f.first.id)?.ledger.samples.count == 2)
        #expect(try Data(contentsOf: store.stateURL) == originalState)
        #expect(try Data(contentsOf: legacy) == damaged)
    }

    @Test func snapshotWrittenBeforeStorageRefactorRemainsReadable() throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let fixture = try #require(Bundle.module.url(forResource: "native-v2-before-storage-refactor",
                                                     withExtension: "json", subdirectory: "Fixtures"))
        let previousBytes = try Data(contentsOf: fixture)
        let directory = f.root.appendingPathComponent("native-v2")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stateURL = directory.appendingPathComponent("state.json")
        try previousBytes.write(to: stateURL)
        f.defaults.set(Data("invalid-catalog".utf8), forKey: "airportCatalog.v1")
        var services = f.vault.services
        services.readCredential = { _ in throw TrafficError.storage }

        let store = try NativeRepository(root: f.root, defaults: f.defaults, services: services)
        let source = try #require(store.source(for: f.first.id))
        let original = try JSONDecoder().decode(Ledger.self, from: f.original)
        #expect(source.ledger.samples.map(\.id) == original.samples.map(\.id))
        #expect(source.resetRule == f.rule)
        #expect(source.threshold == 7.5)
        #expect(store.snapshot.catalog.profiles.count == 2)
        #expect(try Data(contentsOf: stateURL) == previousBytes)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("migration-candidate.json").path))
    }

    @Test func sourceRevisionRejectsLateWriteAfterRuleEdit() throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open(), before = try #require(store.source(for: f.first.id))
        var rule = f.rule; rule.kind = .once
        _ = try store.saveAirport(profile: f.first, name: f.first.name, plan: f.first.plan, subscription: "", reset: rule, threshold: 6)
        #expect(throws: (any Error).self) { try store.updateSource(before) }
        #expect(store.source(for: f.first.id)?.resetRevisions.count == 2)
        #expect(try f.open().source(for: f.first.id)?.resetRule == rule)
        #expect(store.source(for: f.first.id)?.ledger.samples.count == 2)
    }

    @Test func failedReadingPersistenceKeepsBaselineForRetry() async throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        var fail = true
        let workspace = AirportWorkspace(defaults: f.defaults, historyDirectory: f.root, services: f.vault.services, startAutomatically: false,
                                         checkpoint: { if fail && $0 == .beforePublish { throw TrafficError.storage } })
        let model = workspace.model(for: f.first)
        await model.refresh()
        #expect(model.ledger.samples.count == 2 && model.error != nil)
        #expect(try f.open().source(for: f.first.id)?.ledger.samples.count == 2)
        fail = false; await model.refresh()
        #expect(model.ledger.samples.count == 3 && model.error == nil)
        #expect(try f.open().source(for: f.first.id)?.ledger.samples.count == 3)
        try f.assertOriginals()
    }

    @Test func archiveAndRestorePersistGapWithoutDroppingHistory() throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let workspace = AirportWorkspace(defaults: f.defaults, historyDirectory: f.root, services: f.vault.services, startAutomatically: false)
        workspace.archive(f.first, archived: true)
        let archived = try #require(workspace.repository?.source(for: f.first.id))
        #expect(archived.ledger.samples.count == 2 && archived.gaps.count == 1)
        #expect(workspace.repository?.snapshot.catalog.menuAirport == nil)
        workspace.archive(workspace.profiles[0], archived: false)
        let restored = try #require(try f.open().source(for: f.first.id))
        #expect(restored.gaps.count == 1 && restored.gaps[0].restoredAt != nil)
        #expect(restored.ledger.samples.map(\.id) == archived.ledger.samples.map(\.id))
    }

    @Test func invalidConfigurationFailsBeforeStagingCredentials() throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open(), before = try Data(contentsOf: store.stateURL)
        #expect(throws: (any Error).self) { try store.saveAirport(profile: f.first, name: "", plan: "", subscription: "http://bad.example", reset: f.rule, threshold: 8) }
        #expect(try Data(contentsOf: store.stateURL) == before)
        #expect(f.vault.credentials.count == 2)
    }

    @Test func orphanRequiresExplicitAssociationAndCannotReplaceActiveSource() throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let name = "40000000-0000-0000-0000-000000000001.json"
        try f.original.write(to: f.root.appendingPathComponent(name))
        let attempt = SyncAttempt(date: Date(), subscription: nil, message: "连接超时")
        try JSONEncoder().encode([attempt]).write(to: f.root.appendingPathComponent(name + ".sync"))
        let store = try f.open()
        #expect(store.unassociatedHistories.count == 1)
        try store.associateLegacyHistory(named: name, with: f.first.id)
        #expect(store.unassociatedHistories.isEmpty)
        #expect(store.source(for: f.first.id)?.id == f.first.historyID)
        #expect(store.history(for: f.first.id).last?.importedLegacyFile == name)
        #expect(store.history(for: f.first.id).last?.syncAttempts.first?.id == attempt.id)
        #expect(store.history(for: f.first.id).last?.endedAt != nil)
        #expect(throws: (any Error).self) { try store.associateLegacyHistory(named: name, with: f.first.id) }
        #expect(try f.open().history(for: f.first.id).count == 2)
        #expect(f.vault.credentials.count == 2)
    }

    @Test func syncAttemptsAndPendingLinkSurviveRestartWithoutReplayingSample() async throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let attempt = SyncAttempt(date: Date(timeIntervalSinceReferenceDate: 800000400), subscription: nil, message: "连接超时")
        let log = try JSONEncoder().encode([attempt])
        try log.write(to: f.root.appendingPathComponent("\(f.first.historyID).json.sync"))
        let store = try f.open()
        #expect(store.source(for: f.first.id)?.syncAttempts.first?.id == attempt.id)
        _ = try f.change(store)
        let workspace = AirportWorkspace(defaults: f.defaults, historyDirectory: f.root, services: f.vault.services, startAutomatically: false)
        let model = workspace.model(for: f.first)
        #expect(model.linkVerificationPending && model.ledger.samples.count == 2)
        await model.refresh()
        #expect(model.ledger.samples.count == 3)
        #expect(model.syncAttempts.count == 2)
        let reopened = try f.open()
        #expect(reopened.source(for: f.first.id)?.ledger.samples.count == 3)
        #expect(reopened.source(for: f.first.id)?.syncAttempts.last?.id == attempt.id)
        #expect(try Data(contentsOf: f.root.appendingPathComponent("\(f.first.historyID).json.sync")) == log)
        let attributes = try FileManager.default.attributesOfItem(atPath: reopened.stateURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func legacyBackupCanBeReplayedWithoutDeletingV2Records() throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open()
        _ = try f.change(store, mode: .newSource)
        let v2Bytes = try Data(contentsOf: store.stateURL)
        let rollbackRoot = f.root.appendingPathComponent("rollback-rehearsal")
        try FileManager.default.createDirectory(at: rollbackRoot, withIntermediateDirectories: true)
        for profile in f.catalog.profiles {
            let name = "\(profile.historyID).json"
            try FileManager.default.copyItem(at: f.root.appendingPathComponent(name), to: rollbackRoot.appendingPathComponent(name))
        }
        let suite = "Rollback.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let backup = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: store.directory.appendingPathComponent("legacy-preferences.plist")), format: nil) as? [String: Any])
        for (key, value) in backup { defaults.set(value, forKey: key) }
        let restored = try NativeRepository(root: rollbackRoot, defaults: defaults, services: f.vault.services)
        #expect(restored.source(for: f.first.id)?.ledger.samples.count == 2)
        #expect(restored.source(for: f.first.id)?.id == f.first.historyID)
        #expect(restored.source(for: f.first.id)?.resetRule == f.rule)
        #expect(restored.source(for: f.first.id)?.threshold == 7.5)
        #expect(restored.snapshot.catalog.profiles[1].archived)
        #expect(try Data(contentsOf: store.stateURL) == v2Bytes)
        #expect(store.history(for: f.first.id).count == 2)
        let report = try JSONDecoder().decode(MigrationReport.self, from: Data(contentsOf: store.directory.appendingPathComponent("migration-report.json")))
        #expect(report.samples == 4 && report.profiles == 2)
    }

    @Test func explicitSnapshotRecoveryPreservesDamagedFileAndOlderHistory() throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open(); _ = try f.change(store)
        let damaged = Data("broken-state".utf8)
        try damaged.write(to: store.stateURL)
        #expect(throws: (any Error).self) { try f.open() }
        try NativeRepository.restorePreviousSnapshot(root: f.root)
        let restored = try f.open()
        #expect(restored.source(for: f.first.id)?.ledger.samples.count == 2)
        #expect(restored.source(for: f.first.id)?.credentialReference == "legacy-a")
        let preserved = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("preserved-") }
        #expect(preserved.count == 1)
        #expect(try Data(contentsOf: preserved[0]) == damaged)
        try f.assertOriginals()
    }

    @Test func recoveryWithoutValidBackupDoesNotReplaceCurrentFile() throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open(), before = try Data(contentsOf: store.stateURL)
        #expect(throws: (any Error).self) { try NativeRepository.restorePreviousSnapshot(root: f.root) }
        #expect(try Data(contentsOf: store.stateURL) == before)
    }
}
