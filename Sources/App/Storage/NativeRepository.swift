import Foundation
import Darwin
#if SWIFT_PACKAGE
import TrafficCore
#endif

enum RepositoryCheckpoint: CaseIterable {
    case migrationPrepared, migrationPublished, prepared, credentialStaged, beforePublish, published, beforeCleanup
}

// A test-only injected process interruption must leave the journal just as a killed process would.
enum RepositoryInterruption: Error { case simulatedCrash }
enum RepositoryConflict: Error { case stale, busy }

struct ObservationContext {
    let airportID: UUID
    let sourceID: String
    let credentialReference: String
    let readRevision: UUID
    let externalReadGeneration: UUID?
    let enabled: Bool
    let archived: Bool
}

enum SubscriptionReadOutcome {
    case success(Subscription)
    case failure(String)
}

private struct CommitIntent: Codable {
    var version = 1
    var revision: UUID
    var stagedCredential: String?
}

/// The v2 document is the atomic publication boundary. Legacy ledgers and preferences
/// are never used as write targets. Credential values exist only in Keychain.
@MainActor
final class NativeRepository {
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SurgeTrafficMonitor")
    }
    let root: URL
    let directory: URL
    private let services: MonitorServices
    private let checkpoint: (RepositoryCheckpoint) throws -> Void
    private(set) var snapshot: NativeSnapshot
    private(set) var recoveryPending = false
    private var externalReadGenerations: [UUID: UUID] = [:]
    var onExternalChange: ((NativeSnapshot, NativeSnapshot, UUID?) -> Void)?
    var stateURL: URL { directory.appendingPathComponent("state.json") }
    var backupURL: URL { directory.appendingPathComponent("previous-state.json") }
    private var intentURL: URL { directory.appendingPathComponent("commit.json") }

    init(root: URL, defaults: UserDefaults, services: MonitorServices,
         checkpoint: @escaping (RepositoryCheckpoint) throws -> Void = { _ in }) throws {
        self.root = root; directory = root.appendingPathComponent("native-v2", isDirectory: true)
        self.services = services; self.checkpoint = checkpoint
        let lock = try Self.lock(directory)
        defer { flock(lock, LOCK_UN); close(lock) }
        let state = directory.appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: state.path) {
            snapshot = try JSONDecoder().decode(NativeSnapshot.self, from: Data(contentsOf: state))
            try snapshot.validate()
        } else {
            snapshot = try LegacyMigration.migrate(root: root, defaults: defaults, services: services)
            try snapshot.validate()
            try Self.prepareDirectory(directory)
            // A failed migration retry reuses its first candidate identity and backup.
            let candidateURL = directory.appendingPathComponent("migration-candidate.json")
            if FileManager.default.fileExists(atPath: candidateURL.path) {
                let candidate = try JSONDecoder().decode(NativeSnapshot.self, from: Data(contentsOf: candidateURL))
                try candidate.validate()
                let backup = try PropertyListSerialization.propertyList(from: Data(contentsOf: directory.appendingPathComponent("legacy-preferences.plist")), format: nil) as? [String: Any]
                guard candidate.migration.files.map(\.sha256) == snapshot.migration.files.map(\.sha256),
                      candidate.migration.files.map(\.name) == snapshot.migration.files.map(\.name),
                      let backup, NSDictionary(dictionary: backup).isEqual(to: LegacyMigration.legacyPreferences(defaults)) else { throw TrafficError.storage }
                snapshot = candidate
            } else {
                let keys = LegacyMigration.legacyPreferences(defaults)
                try Self.write(try PropertyListSerialization.data(fromPropertyList: keys, format: .binary, options: 0),
                               to: directory.appendingPathComponent("legacy-preferences.plist"))
                try Self.write(try JSONEncoder().encode(snapshot), to: candidateURL)
            }
            try Self.write(try JSONEncoder().encode(snapshot.migration), to: directory.appendingPathComponent("migration-report.json"))
            try checkpoint(.migrationPrepared)
            try Self.write(try JSONEncoder().encode(snapshot), to: state)
            try checkpoint(.migrationPublished)
        }
        try recoverCommit()
    }

    private static func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private static func lock(_ directory: URL) throws -> Int32 {
        try prepareDirectory(directory)
        let descriptor = open(directory.appendingPathComponent("store.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw TrafficError.storage }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let reason = errno
            close(descriptor)
            if reason == EWOULDBLOCK || reason == EAGAIN { throw RepositoryConflict.busy }
            throw TrafficError.storage
        }
        return descriptor
    }
    private static func write(_ data: Data, to url: URL) throws {
        try prepareDirectory(url.deletingLastPathComponent())
        // Permissions are part of the staged file, before rename/publication.
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw TrafficError.storage }
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize(); try handle.close()
        guard rename(temporary.path, url.path) == 0 else { throw TrafficError.storage }
    }

    func source(for airportID: UUID) -> SourceRecord? {
        guard let profile = snapshot.catalog.profiles.first(where: { $0.id == airportID }) else { return nil }
        return snapshot.sources.first { $0.id == profile.historyID && $0.airportID == airportID }
    }
    func history(for airportID: UUID) -> [SourceRecord] { snapshot.sources.filter { $0.airportID == airportID } }
    func externalReadGeneration(for airportID: UUID) -> UUID? { externalReadGenerations[airportID] }

    /// Remember externally changed read contexts separately from local edits.
    @discardableResult
    private func adopt(_ published: NativeSnapshot) -> NativeSnapshot? {
        guard published.revision != snapshot.revision else { return nil }
        let previous = snapshot
        let ids = Set(previous.catalog.profiles.map(\.id) + published.catalog.profiles.map(\.id))
        for id in ids {
            let before = previous.catalog.profiles.first { $0.id == id }
            let after = published.catalog.profiles.first { $0.id == id }
            let oldSource = before.flatMap { profile in previous.sources.first { $0.id == profile.historyID && $0.airportID == id } }
            let newSource = after.flatMap { profile in published.sources.first { $0.id == profile.historyID && $0.airportID == id } }
            if before?.historyID != after?.historyID || before?.enabled != after?.enabled || before?.archived != after?.archived ||
                oldSource?.credentialReference != newSource?.credentialReference ||
                oldSource?.effectiveReadContextRevision != newSource?.effectiveReadContextRevision {
                externalReadGenerations[id] = UUID()
            }
        }
        snapshot = published
        return previous
    }

    /// Load other instances' committed state before starting work from local state.
    func synchronize() throws {
        var previous: NativeSnapshot?
        defer { if let previous { onExternalChange?(previous, snapshot, nil) } }
        let lock = try Self.lock(directory)
        defer { flock(lock, LOCK_UN); close(lock) }
        let published = try readPublishedSnapshot()
        previous = adopt(published)
        try recoverCommit()
    }

    private func readPublishedSnapshot() throws -> NativeSnapshot {
        let published = try JSONDecoder().decode(NativeSnapshot.self, from: Data(contentsOf: stateURL))
        try published.validate()
        return published
    }

    /// Only these changes make a response from an already-started read unsafe.
    private static func sameReadContext(_ first: SourceRecord, _ second: SourceRecord) throws -> Bool {
        guard first.id == second.id, first.credentialReference == second.credentialReference,
              first.needsVerification == second.needsVerification else { return false }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(first.ledger) == encoder.encode(second.ledger)
            && encoder.encode(first.resetRevisions) == encoder.encode(second.resetRevisions)
    }

    var unassociatedHistories: [LegacyFileRecord] {
        snapshot.migration.files.filter { file in
            file.name.hasSuffix(".json") && !snapshot.sources.contains(where: { "\($0.id).json" == file.name })
        }
    }

    /// This API requires an explicit airport choice. It imports read-only history,
    /// never a current source or guessed credential/reset configuration.
    func associateLegacyHistory(named name: String, with airportID: UUID) throws {
        guard snapshot.catalog.profiles.contains(where: { $0.id == airportID }),
              let file = unassociatedHistories.first(where: { $0.name == name }) else { throw TrafficError.storage }
        let data = try Data(contentsOf: root.appendingPathComponent(name))
        guard LegacyMigration.digest(data) == file.sha256 else { throw TrafficError.storage }
        let ledger = try JSONDecoder().decode(Ledger.self, from: data); try ledger.validate()
        var attempts: [SyncAttempt] = []
        if let log = snapshot.migration.files.first(where: { $0.name == name + ".sync" }) {
            let bytes = try Data(contentsOf: root.appendingPathComponent(log.name))
            guard LegacyMigration.digest(bytes) == log.sha256 else { throw TrafficError.storage }
            attempts = try JSONDecoder().decode([SyncAttempt].self, from: bytes)
        }
        let id = String(name.dropLast(5)), now = services.now()
        var next = snapshot
        next.sources.append(SourceRecord(id: id, airportID: airportID, credentialReference: "unavailable",
            createdAt: ledger.samples.first?.date ?? now, endedAt: now, ledger: ledger, syncAttempts: attempts,
            resetRevisions: [ResetRevision(effectiveAt: nil, rule: ResetRule())], threshold: 10,
            migratedNotificationAt: ledger.lowBalanceNotified ? now : nil, importedLegacyFile: name))
        try commit(next)
    }

    /// Recovery chooses using the published revision, never the UI's last message.
    private func recoverCommit() throws {
        guard FileManager.default.fileExists(atPath: intentURL.path) else { recoveryPending = false; return }
        recoveryPending = true
        let intent = try JSONDecoder().decode(CommitIntent.self, from: Data(contentsOf: intentURL))
        guard intent.version == 1 else { throw TrafficError.storage }
        if let account = intent.stagedCredential {
            guard account.hasPrefix("staged-"), UUID(uuidString: String(account.dropFirst(7))) != nil else { throw TrafficError.storage }
        }
        if snapshot.revision != intent.revision, let account = intent.stagedCredential {
            guard !snapshot.sources.contains(where: { $0.credentialReference == account }) else { throw TrafficError.storage }
            try services.deleteCredential(account)
        }
        try FileManager.default.removeItem(at: intentURL)
        recoveryPending = false
    }

    private func commit(_ value: NativeSnapshot, credential: (String, String)? = nil) throws {
        var previous: NativeSnapshot?
        defer { if let previous { onExternalChange?(previous, snapshot, nil) } }
        let lock = try Self.lock(directory)
        defer { flock(lock, LOCK_UN); close(lock) }
        let published = try readPublishedSnapshot()
        if let old = adopt(published) {
            previous = old
            try recoverCommit()
            throw RepositoryConflict.stale
        }
        try commitLocked(value, credential: credential)
    }

    private func commitLocked(_ value: NativeSnapshot, credential: (String, String)? = nil) throws {
        try recoverCommit()
        var next = value; next.revision = UUID(); try next.validate()
        let intent = CommitIntent(revision: next.revision, stagedCredential: credential?.0)
        try Self.write(try JSONEncoder().encode(intent), to: intentURL)
        do {
            try checkpoint(.prepared)
            if let (account, secret) = credential { try services.saveCredential(secret, account) }
            try checkpoint(.credentialStaged)
            try checkpoint(.beforePublish)
            try Self.write(try JSONEncoder().encode(snapshot), to: backupURL)
            try Self.write(try JSONEncoder().encode(next), to: stateURL)
            snapshot = next
            try checkpoint(.published)
            try checkpoint(.beforeCleanup)
            try recoverCommit()
        } catch is RepositoryInterruption {
            recoveryPending = true
            throw RepositoryInterruption.simulatedCrash
        } catch {
            // Once the atomic publish succeeded, cleanup failure is not a failed save.
            if snapshot.revision == next.revision {
                recoveryPending = true
                return
            }
            do { try recoverCommit() } catch { recoveryPending = true }
            throw error
        }
    }

    /// Rebase a completed read onto the latest snapshot under the same file lock.
    /// A change to its read context discards the result rather than guessing its identity.
    func recordRead(_ outcome: SubscriptionReadOutcome, at date: Date, context: ObservationContext) throws -> SourceRecord? {
        var previous: NativeSnapshot?
        var preserveRequest: UUID?
        defer { if let previous { onExternalChange?(previous, snapshot, preserveRequest) } }
        let lock = try Self.lock(directory)
        defer { flock(lock, LOCK_UN); close(lock) }
        let published = try readPublishedSnapshot()
        previous = adopt(published)
        try recoverCommit()
        guard let profile = snapshot.catalog.profiles.first(where: { $0.id == context.airportID }),
              profile.historyID == context.sourceID, profile.enabled == context.enabled,
              profile.archived == context.archived,
              let index = snapshot.sources.firstIndex(where: { $0.id == context.sourceID && $0.airportID == context.airportID }),
              snapshot.sources[index].credentialReference == context.credentialReference,
              // Local edits already go through the model's request lifecycle.
              // External changes must match the captured read context, even if
              // another operation synchronized them before this response arrived.
              (externalReadGeneration(for: context.airportID) == context.externalReadGeneration ||
               snapshot.sources[index].effectiveReadContextRevision == context.readRevision) else { return nil }
        var next = snapshot
        var source = next.sources[index]
        switch outcome {
        case .success(let reading):
            if let last = source.ledger.samples.last {
                source.lastContinuity = reading.upload < last.subscription.upload || reading.download < last.subscription.download ? .counterChanged :
                    reading.total != last.subscription.total ? .quotaChanged :
                    source.resetRule.crosses(last.date, date) ? .resetBoundary : .continued
            } else { source.lastContinuity = .baseline }
            try source.ledger.append(reading, at: date)
            source.needsVerification = false
            source.syncAttempts.insert(SyncAttempt(date: date, subscription: reading, message: nil), at: 0)
            source.readContextRevision = UUID()
        case .failure(let message):
            source.syncAttempts.insert(SyncAttempt(date: date, subscription: nil, message: message), at: 0)
            source.readContextRevision = source.effectiveReadContextRevision
        }
        source.revision = UUID()
        next.sources[index] = source
        try commitLocked(next)
        preserveRequest = context.airportID
        return snapshot.sources[index]
    }

    /// Explicit recovery only. Preserve damaged bytes and never silently turn an
    /// unreadable document into an empty workspace. Pending commits need reconciliation first.
    static func restorePreviousSnapshot(root: URL) throws {
        let directory = root.appendingPathComponent("native-v2")
        let lock = try Self.lock(directory)
        defer { flock(lock, LOCK_UN); close(lock) }
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("commit.json").path) else { throw TrafficError.storage }
        let bytes = try Data(contentsOf: directory.appendingPathComponent("previous-state.json"))
        let previous = try JSONDecoder().decode(NativeSnapshot.self, from: bytes); try previous.validate()
        let state = directory.appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: state.path) {
            try Self.write(try Data(contentsOf: state), to: directory.appendingPathComponent("preserved-\(UUID().uuidString).json"))
        }
        try Self.write(bytes, to: state)
    }

    @discardableResult
    func saveAirport(profile: AirportProfile?, name: String, plan: String, subscription: String,
                     reset: ResetRule, threshold: Double, change: SubscriptionChange = .sameSource,
                     reminderPreferences: ReminderPreferences? = nil, airportRemindersEnabled: Bool? = nil,
                     initialReading: SubscriptionPreview.Result? = nil) throws -> AirportProfile {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, threshold.isFinite, threshold > 0, threshold <= 1_000_000 else { throw TrafficError.storage }
        try reset.validate()
        if let reminderPreferences, !reminderPreferences.isValid { throw TrafficError.storage }
        if initialReading != nil && profile != nil { throw TrafficError.storage }
        let url = subscription.isEmpty ? nil : try Subscription.validatedURL(subscription).absoluteString
        var next = snapshot
        var saved: AirportProfile
        if let profile {
            guard let current = next.catalog.profiles.first(where: { $0.id == profile.id }) else { throw TrafficError.storage }
            saved = current
        } else {
            guard url != nil else { throw TrafficError.invalidURL }
            saved = AirportProfile(id: UUID(), historyID: UUID().uuidString, credentialAccount: "airport-\(UUID().uuidString)",
                                   name: name, plan: plan, enabled: true, archived: false)
        }
        let now = services.now()
        var record = source(for: saved.id)
        let previousReminderConfiguration = record
        if change == .newSource {
            guard url != nil else { throw TrafficError.invalidURL }
            if let old = record, let index = next.sources.firstIndex(where: { $0.id == old.id }) { next.sources[index].endedAt = now }
            saved.historyID = UUID().uuidString; record = nil
        }
        var source = record ?? SourceRecord(id: saved.historyID, airportID: saved.id, credentialReference: saved.credentialAccount,
            createdAt: now, ledger: Ledger(), syncAttempts: [], resetRevisions: [ResetRevision(effectiveAt: initialReading?.readAt ?? now, rule: reset)], threshold: threshold)
        if record == nil {
            if let previous = previousReminderConfiguration {
                source.reminderPreferences = previous.reminderPreferences
                source.airportRemindersEnabled = previous.airportRemindersEnabled
                source.notifyForecast = previous.notifyForecast; source.notifyExpiry = previous.notifyExpiry
                source.thresholdMode = previous.thresholdMode
                source.threshold = previous.threshold
            } else { source.reminderPreferences = ReminderPreferences() }
        }
        var credential: (String, String)?
        if let url {
            let old = record == nil ? nil : try services.readCredential(source.credentialReference)
            if old != url {
                let reference = "staged-\(UUID().uuidString)"
                credential = (reference, url); source.credentialReference = reference
                source.needsVerification = true
                source.clearReminderConfirmations()
            }
        }
        if source.resetRule != reset {
            source.resetRevisions.append(ResetRevision(effectiveAt: now, rule: reset))
            source.needsVerification = true
            source.clearReminderConfirmations()
        }
        if source.threshold != threshold { source.thresholdMode = .legacyAbsoluteGB }
        if source.threshold != threshold, var preferences = source.reminderPreferences {
            preferences.thresholdMode = .legacyAbsoluteGB; preferences.lowThreshold = threshold
            source.reminderPreferences = preferences
        }
        source.threshold = threshold
        if let reminderPreferences {
            if source.reminderPreferences != reminderPreferences { source.clearReminderConfirmations() }
            source.reminderPreferences = reminderPreferences
        }
        if let airportRemindersEnabled {
            if (source.airportRemindersEnabled ?? true) != airportRemindersEnabled { source.clearReminderConfirmations() }
            source.airportRemindersEnabled = airportRemindersEnabled
        }
        if let initialReading {
            guard initialReading.url.absoluteString == url, initialReading.readAt <= now else { throw TrafficError.storage }
            try source.ledger.append(initialReading.subscription, at: initialReading.readAt)
            source.syncAttempts = [SyncAttempt(date: initialReading.readAt, subscription: initialReading.subscription, message: nil)]
            source.needsVerification = false; source.lastContinuity = .baseline
        }
        if let record {
            source.readContextRevision = try Self.sameReadContext(record, source) ? record.effectiveReadContextRevision : UUID()
        } else { source.readContextRevision = UUID() }
        source.revision = UUID()
        saved.name = name; saved.plan = plan
        if let index = next.catalog.profiles.firstIndex(where: { $0.id == saved.id }) { next.catalog.profiles[index] = saved }
        else { next.catalog.profiles.append(saved) }
        if let index = next.sources.firstIndex(where: { $0.id == source.id }) { next.sources[index] = source }
        else { next.sources.append(source) }
        if next.catalog.menuAirport == nil && !saved.archived { next.catalog.menuAirport = saved.id }
        try commit(next, credential: credential)
        return saved
    }

    func updateSource(_ source: SourceRecord) throws {
        guard let active = self.source(for: source.airportID), active.id == source.id,
              active.credentialReference == source.credentialReference, active.revision == source.revision,
              let index = snapshot.sources.firstIndex(where: { $0.id == source.id }) else { throw TrafficError.storage }
        var next = snapshot; next.sources[index] = source
        next.sources[index].readContextRevision = try Self.sameReadContext(active, source) ? active.effectiveReadContextRevision : UUID()
        next.sources[index].revision = UUID(); try commit(next)
    }

    func updateCatalog(_ catalog: AirportCatalog) throws {
        var next = snapshot; next.catalog = catalog
        for profile in catalog.profiles {
            guard let old = snapshot.catalog.profiles.first(where: { $0.id == profile.id }),
                  old.archived != profile.archived || old.enabled != profile.enabled,
                  let index = next.sources.firstIndex(where: { $0.id == profile.historyID }) else { continue }
            next.sources[index].needsVerification = true
            next.sources[index].clearReminderConfirmations()
            if profile.archived && !old.archived {
                next.sources[index].gaps.append(MonitoringGap(removedAt: services.now(), lastSampleID: next.sources[index].ledger.samples.last?.id))
            } else if old.archived && !profile.archived, let gap = next.sources[index].gaps.indices.last { next.sources[index].gaps[gap].restoredAt = services.now() }
            next.sources[index].readContextRevision = UUID()
            next.sources[index].revision = UUID()
        }
        try commit(next)
    }

    func setStatisticsTimeZone(_ identifier: String) throws {
        guard TimeZone(identifier: identifier) != nil else { throw TrafficError.storage }
        guard snapshot.statisticsTimeZone != identifier else { return }
        var next = snapshot; next.statisticsTimeZone = identifier
        try commit(next)
    }

    /// Acknowledges only the published intention, including after a source change.
    /// It cannot replace credentials, samples, configuration or another delivery.
    func updateReminderRecord(sourceID: String, deliveryID: String, state: ReminderState?, delivery: ReminderDelivery?,
                              unconfirmedDeliveries: [ReminderDelivery]? = nil) throws {
        guard let index = snapshot.sources.firstIndex(where: { $0.id == sourceID }),
              snapshot.sources[index].reminderDelivery?.id == deliveryID else { throw TrafficError.storage }
        var next = snapshot
        next.sources[index].readContextRevision = snapshot.sources[index].effectiveReadContextRevision
        next.sources[index].reminderState = state
        next.sources[index].reminderDelivery = delivery
        if let unconfirmedDeliveries { next.sources[index].reminderUnconfirmedDeliveries = unconfirmedDeliveries }
        next.sources[index].revision = UUID()
        try commit(next)
    }
}
