import Foundation
import Testing
import TrafficCore
import UserNotifications
@testable import NativeModels

@MainActor final class ReminderIntegrationFixture {
    let original: NativeRepositoryFixture
    var now = Date(timeIntervalSince1970: 1_792_497_600)
    var used: UInt64 = 95_000_000_000
    var expiry: Date?
    var failFetch = false
    var failCommit = false
    var authorization: UNAuthorizationStatus = .authorized
    var authorizationRequests = 0
    var sends = 0
    var reasons: [[ReminderReason]] = []
    var store: NativeRepository!
    var model: MonitorModel!

    init() throws {
        original = try NativeRepositoryFixture()
        original.defaults.set(true, forKey: "remindersEnabled")
        expiry = now.addingTimeInterval(30 * 86400)
    }

    var services: MonitorServices {
        var result = original.vault.services
        result.now = { self.now }
        result.fetch = { _ in
            if self.failFetch { throw TrafficError.network(-1009) }
            return try Subscription(upload: 0, download: self.used, total: 100_000_000_000, expiry: self.expiry)
        }
        result.notificationAuthorizationStatus = { self.authorization }
        result.requestNotificationAuthorization = { self.authorizationRequests += 1; return false }
        result.reminderServices = ReminderServices(authorizationStatus: { self.authorization },
            send: { _, _, reasons in self.sends += 1; self.reasons.append(reasons) },
            queryAcceptance: { _ in .unknown }, now: { self.now })
        return result
    }

    func open() throws {
        store = try NativeRepository(root: original.root, defaults: original.defaults, services: services,
            checkpoint: { [weak self] point in
                if self?.failCommit == true && point == .beforePublish { throw TrafficError.storage }
            })
    }

    func makeModel() {
        model?.stop()
        let source = store.source(for: original.first.id)!
        model = MonitorModel(profileID: source.id, credentialAccount: original.first.credentialAccount,
            defaults: original.defaults, services: services, historyDirectory: original.root,
            startAutomatically: false, repository: store, airportID: original.first.id)
    }

    func source() throws -> SourceRecord { try #require(store.source(for: original.first.id)) }

    func seed() throws {
        var source = try source()
        var ledger = Ledger()
        try ledger.append(Subscription(upload: 0, download: used, total: 100_000_000_000, expiry: expiry), at: now)
        source.ledger = ledger
        source.syncAttempts = []
        source.needsVerification = false
        source.migratedNotificationAt = nil
        source.threshold = 10
        source.thresholdMode = .percent
        source.reminderPreferences = ReminderPreferences(forecastEnabled: false, expiryEnabled: false)
        source.reminderState = ReminderState()
        source.reminderDelivery = nil
        try store.updateSource(source)
    }

    func advance(_ seconds: TimeInterval = 300) { now = now.addingTimeInterval(seconds) }

    func seedForecast() throws {
        try seed()
        var source = try source(), ledger = Ledger(), rule = ResetRule()
        rule.kind = .monthly; rule.day = 28; rule.timeZoneID = "UTC"
        for day in 0...4 {
            try ledger.append(Subscription(upload: 0, download: UInt64(55 + day * 10) * 1_000_000_000,
                                           total: 100_000_000_000, expiry: expiry),
                              at: now.addingTimeInterval(Double(day - 4) * 86400))
        }
        source.ledger = ledger
        source.resetRevisions = [ResetRevision(effectiveAt: nil, rule: rule)]
        source.reminderPreferences = ReminderPreferences(lowEnabled: false, forecastEnabled: true, expiryEnabled: false)
        try store.updateSource(source)
    }

    func cleanup() { model?.stop(); original.cleanup() }
}
