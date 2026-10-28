import Testing
import Foundation
import TrafficCore
@testable import NativeModels

@Suite @MainActor
struct SubscriptionIsolationTests {
    @MainActor final class Vault {
        var credentials: [String: String] = [:]
        var failSave = false
        var failFetch = false
        var used: UInt64 = 10
        var fetchedHosts: [String] = []
        var services: MonitorServices {
            MonitorServices(readCredential: { self.credentials[$0] }, saveCredential: { value, account in
                if self.failSave { throw TrafficError.storage }; self.credentials[account] = value
            }, deleteCredential: { self.credentials.removeValue(forKey: $0) }, fetch: { url in
                self.fetchedHosts.append(url.host ?? "")
                if self.failFetch { throw TrafficError.network(-1009) }
                return try TrafficCore.Subscription(upload: 0, download: self.used, total: 100)
            }, notificationAuthorizationStatus: { .notDetermined })
        }
    }
    @Test func twoAirportsNeverShareCredentialsOrLedgers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults(suiteName: "Isolation.\(UUID().uuidString)")!, vault = Vault()
        let a = MonitorModel(profileID: UUID().uuidString, credentialAccount: "a", defaults: defaults, services: vault.services, historyDirectory: directory, startAutomatically: false)
        let b = MonitorModel(profileID: UUID().uuidString, credentialAccount: "b", defaults: defaults, services: vault.services, historyDirectory: directory, startAutomatically: false)
        #expect(await a.saveSubscription("https://a.example/secret-a"))
        vault.used = 40
        #expect(await b.saveSubscription("https://b.example/secret-b"))
        #expect(a.latest?.subscription.used == 10); #expect(b.latest?.subscription.used == 40)
        #expect(a.currentProfileID != b.currentProfileID)
        #expect(vault.credentials["a"] == "https://a.example/secret-a")
        #expect(vault.credentials["b"] == "https://b.example/secret-b")
        #expect(vault.fetchedHosts == ["a.example", "b.example"])
        let restored = MonitorModel(profileID: a.currentProfileID, credentialAccount: "a", defaults: defaults, services: vault.services, historyDirectory: directory, startAutomatically: false)
        #expect(restored.latest?.subscription.used == 10); #expect(restored.syncAttempts.count == 1)
        a.stop(); b.stop(); restored.stop()
    }
    @Test func dailyStatisticsRefreshAfterNewSampleAndSubscriptionReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = Vault(), defaults = UserDefaults(suiteName: "DayCache.\(UUID().uuidString)")!
        let m = MonitorModel(profileID: UUID().uuidString, credentialAccount: "cache", defaults: defaults,
                             services: vault.services, historyDirectory: directory, startAutomatically: false)
        let start = Calendar.current.startOfDay(for: Date())
        #expect(await m.saveSubscription("https://a.example/one"))
        #expect(m.dailyRows(from: start, to: Date()).last?.summary.intervals == 0)
        vault.used = 30
        await m.refresh()
        #expect(m.dailyRows(from: start, to: Date()).last?.summary.bytes == 20)
        #expect(m.dailyRows(from: start, to: Date()).last?.summary.intervals == 1)
        #expect(await m.saveSubscription("https://a.example/two"))
        #expect(m.dailyRows(from: start, to: Date()).last?.summary.intervals == 2)
        #expect(m.dailyRows(from: start, to: Date()).last?.summary.bytes == 20)
        m.stop()
    }
    @Test func explicitNewSourceStartsSeparateHistoryAndRetainsOldFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = UserDefaults(suiteName: "Identity.\(UUID().uuidString)")!, vault = Vault()
        let m = MonitorModel(profileID: UUID().uuidString, credentialAccount: "a", defaults: defaults, services: vault.services, historyDirectory: directory, startAutomatically: false)
        #expect(await m.saveSubscription("https://a.example/one"))
        let oldID = m.currentProfileID
        vault.used = 30; #expect(await m.saveSubscription("https://a.example/two", change: .newSource))
        #expect(m.currentProfileID != oldID); #expect(m.ledger.samples.count == 1)
        #expect(try HistoryStore(url: directory.appendingPathComponent("\(oldID).json")).load().samples.count == 1)
        #expect(defaults.string(forKey: "historyProfile.a") == m.currentProfileID)
        m.stop()
    }
    @Test func failedCredentialSaveKeepsIdentityAndReadings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = Vault(), defaults = UserDefaults(suiteName: "SaveFailure.\(UUID().uuidString)")!
        let m = MonitorModel(profileID: UUID().uuidString, credentialAccount: "a", defaults: defaults, services: vault.services, historyDirectory: directory, startAutomatically: false)
        #expect(await m.saveSubscription("https://a.example/one")); let original = m.currentProfileID
        vault.failSave = true
        #expect(await m.saveSubscription("https://a.example/two") == false)
        #expect(m.currentProfileID == original); #expect(m.latest?.subscription.used == 10)
        #expect(vault.credentials["a"] == "https://a.example/one"); m.stop()
    }
    @Test func failedSyncRetainsReadingAndCreatesFailureRecord() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = Vault(), defaults = UserDefaults(suiteName: "FetchFailure.\(UUID().uuidString)")!
        let m = MonitorModel(profileID: UUID().uuidString, credentialAccount: "a", defaults: defaults, services: vault.services, historyDirectory: directory, startAutomatically: false)
        #expect(await m.saveSubscription("https://a.example/one"))
        vault.failFetch = true; await m.refresh()
        #expect(m.latest?.subscription.used == 10); #expect(m.ledger.samples.count == 1)
        #expect(m.error != nil); #expect(m.syncAttempts.count == 2); #expect(m.syncAttempts.first?.succeeded == false)
        m.stop()
    }
    @Test func legacyAccountLoadsOriginalLedgerAndResetWithoutChangingIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID().uuidString, vault = Vault(), suite = "Legacy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(id, forKey: "profileID"); vault.credentials["active-url"] = "https://legacy.example/subscription"
        var rule = ResetRule(); rule.kind = .monthly; rule.day = 20
        defaults.set(try JSONEncoder().encode(rule), forKey: "resetRule.\(id)")
        var ledger = Ledger(); try ledger.append(TrafficCore.Subscription(upload: 12, download: 30, total: 100))
        try HistoryStore(url: directory.appendingPathComponent("\(id).json")).save(ledger)
        let model = MonitorModel(defaults: defaults, services: vault.services, historyDirectory: directory, startAutomatically: false)
        #expect(model.currentProfileID == id); #expect(model.hasURL); #expect(model.latest?.subscription.used == 42)
        #expect(model.resetRule == rule); #expect(vault.fetchedHosts.isEmpty)
        #expect(vault.credentials.count == 1); model.stop()
    }

    @Test func resetRulesRoundTripWithoutReplacingSubscriptionOrReadings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ResetEditor.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!, vault = Vault()
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let model = MonitorModel(profileID: UUID().uuidString, credentialAccount: "reset-editor", defaults: defaults,
                                 services: vault.services, historyDirectory: directory, startAutomatically: false)
        #expect(await model.saveSubscription("https://airport.example/unchanged"))
        let id = model.currentProfileID, reading = model.latest?.subscription.used, samples = model.ledger.samples.count
        model.enabled = false // Preference saves must not start live sampling in this isolated test.
        defer { model.stop() }
        for kind in [ResetKind.monthly, .billing, .once, .none] {
            var rule = ResetRule(); rule.kind = kind; rule.day = 31; rule.hour = 23; rule.minute = 45
            rule.timeZoneID = "America/New_York"; rule.anchor = Date(timeIntervalSince1970: 1_800_000_000)
            await model.savePreferences(interval: 5, reminders: false, threshold: 10, reset: rule)
            #expect(model.resetRule == rule)
            let restored = MonitorModel(profileID: id, credentialAccount: "reset-editor", defaults: defaults,
                                        services: vault.services, historyDirectory: directory, startAutomatically: false)
            #expect(restored.resetRule == rule); restored.stop()
            #expect(model.currentProfileID == id)
            #expect(model.latest?.subscription.used == reading)
            #expect(model.ledger.samples.count == samples)
            #expect(vault.credentials["reset-editor"] == "https://airport.example/unchanged")
            #expect(vault.fetchedHosts.count == 1)
        }
        let saved = model.resetRule
        var invalid = saved; invalid.kind = .monthly; invalid.timeZoneID = "Invalid/Zone"
        await model.savePreferences(interval: 5, reminders: false, threshold: 10, reset: invalid)
        #expect(model.resetRule == saved)
    }
}
