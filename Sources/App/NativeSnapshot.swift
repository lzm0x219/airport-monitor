import Foundation
#if SWIFT_PACKAGE
import TrafficCore
#endif

enum SubscriptionChange: String, Codable { case sameSource, newSource }
enum ThresholdMode: String, Codable { case legacyAbsoluteGB, percent }
enum ContinuityCheck: String, Codable { case baseline, continued, counterChanged, quotaChanged, resetBoundary }

struct ResetRevision: Codable {
    var id = UUID()
    // Nil means the effective date predates migration and is not known.
    var effectiveAt: Date?
    var rule: ResetRule
}

struct MonitoringGap: Codable {
    var id = UUID()
    var removedAt: Date
    var restoredAt: Date?
    var lastSampleID: UUID?
}

struct SourceRecord: Codable, Identifiable {
    var id: String
    var revision = UUID()
    // Changes only when an in-flight subscription reading can no longer be applied.
    // Missing in older snapshots: their existing source revision is the safe fallback.
    var readContextRevision: UUID?
    var airportID: UUID
    var credentialReference: String
    var createdAt: Date
    var endedAt: Date?
    var ledger: Ledger
    var syncAttempts: [SyncAttempt]
    var resetRevisions: [ResetRevision]
    var gaps: [MonitoringGap] = []
    var thresholdMode: ThresholdMode = .legacyAbsoluteGB
    var threshold: Double
    var notifyForecast = false
    var notifyExpiry = false
    var migratedNotificationAt: Date?
    var reminderPreferences: ReminderPreferences?
    var reminderState: ReminderState?
    var reminderDelivery: ReminderDelivery?
    var reminderUnconfirmedDeliveries: [ReminderDelivery]?
    var airportRemindersEnabled: Bool?
    var needsVerification = false
    var lastContinuity: ContinuityCheck?
    var importedLegacyFile: String?
    var resetRule: ResetRule { resetRevisions.last!.rule }
    var effectiveReadContextRevision: UUID { readContextRevision ?? revision }

    mutating func clearReminderConfirmations() {
        reminderState?.lowRecovery = nil; reminderState?.exhaustionRecovery = nil
        reminderState?.forecastTrigger = nil; reminderState?.forecastRecovery = nil
    }
}

struct LegacyFileRecord: Codable {
    var name: String
    var sha256: String
    var samples: Int?
    var associated: Bool
}

struct MigrationReport: Codable {
    var createdAt: Date
    var statisticsTimeZone: String
    var profiles: Int
    var samples: Int
    var files: [LegacyFileRecord]
    var warnings: [String]
}

struct NativeSnapshot: Codable {
    var version = 2
    var revision = UUID()
    var catalog: AirportCatalog
    var sources: [SourceRecord]
    var statisticsTimeZone: String
    var migration: MigrationReport

    func validate() throws {
        guard version == 2, catalog.version == 2, TimeZone(identifier: statisticsTimeZone) != nil else { throw TrafficError.storage }
        try catalog.validate()
        guard Set(sources.map(\.id)).count == sources.count,
              Set(catalog.profiles.map(\.historyID)).count == catalog.profiles.count else { throw TrafficError.storage }
        for source in sources {
            guard UUID(uuidString: source.id) != nil,
                  catalog.profiles.contains(where: { $0.id == source.airportID }),
                  !source.credentialReference.isEmpty, !source.credentialReference.contains("://"),
                  !source.resetRevisions.isEmpty, source.threshold.isFinite, source.threshold > 0,
                  source.threshold <= (source.thresholdMode == .percent ? 50 : 1_000_000) else { throw TrafficError.storage }
            try source.ledger.validate()
            if let preferences = source.reminderPreferences, !preferences.isValid { throw TrafficError.storage }
            if let delivery = source.reminderDelivery, delivery.sourceID != source.id { throw TrafficError.storage }
            if source.reminderUnconfirmedDeliveries?.contains(where: { $0.sourceID != source.id }) == true { throw TrafficError.storage }
            for revision in source.resetRevisions { try revision.rule.validate() }
        }
        for profile in catalog.profiles {
            guard sources.contains(where: { $0.id == profile.historyID && $0.airportID == profile.id && $0.endedAt == nil }) else { throw TrafficError.storage }
        }
        guard catalog.menuAirport == nil || catalog.profiles.contains(where: { $0.id == catalog.menuAirport && !$0.archived }) else { throw TrafficError.storage }
    }
}

