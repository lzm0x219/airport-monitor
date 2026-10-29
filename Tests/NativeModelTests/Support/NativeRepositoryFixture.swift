import Foundation
import Testing
import TrafficCore
@testable import NativeModels

@MainActor final class RepositoryTestVault {
    var credentials = ["legacy-a": "https://a.example/old-secret", "legacy-b": "https://b.example/old-secret"]
    var failSave = false
    var failDelete = false
    var failFetch = false
    var fetches = 0
    var used: UInt64 = 260
    var services: MonitorServices {
        MonitorServices(readCredential: { self.credentials[$0] }, saveCredential: { value, key in
            self.credentials[key] = value
            if self.failSave { throw TrafficError.storage }
        }, deleteCredential: { key in
            if self.failDelete { throw TrafficError.storage }
            self.credentials.removeValue(forKey: key)
        }, fetch: { _ in
            self.fetches += 1
            if self.failFetch { throw TrafficError.network(-1009) }
            return try Subscription(upload: 120, download: self.used, total: 10000, expiry: Date(timeIntervalSinceReferenceDate: 900000000))
        }, notificationAuthorizationStatus: { .denied })
    }
}

@MainActor final class NativeRepositoryFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeMigration-\(UUID())")
    let suite = "NativeMigration.\(UUID())"
    let defaults: UserDefaults
    let vault = RepositoryTestVault()
    var catalog: AirportCatalog
    let original: Data
    let rule: ResetRule
    init() throws {
        defaults = UserDefaults(suiteName: suite)!
        catalog = AirportCatalog(profiles: [
            AirportProfile(id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!, historyID: "30000000-0000-0000-0000-000000000001", credentialAccount: "legacy-a", name: "主力", plan: "旧套餐", enabled: true, archived: false),
            AirportProfile(id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!, historyID: "30000000-0000-0000-0000-000000000002", credentialAccount: "legacy-b", name: "已归档", plan: "备份", enabled: false, archived: true)
        ], menuAirport: UUID(uuidString: "20000000-0000-0000-0000-000000000001"))
        let fixture = try #require(Bundle.module.url(forResource: "legacy-ledger-v1", withExtension: "json", subdirectory: "Fixtures"))
        original = try Data(contentsOf: fixture)
        var r = ResetRule(); r.kind = .billing; r.day = 31; r.hour = 23; r.minute = 45; r.timeZoneID = "America/New_York"; r.anchor = Date(timeIntervalSinceReferenceDate: 799000000); rule = r
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for profile in catalog.profiles {
            try original.write(to: root.appendingPathComponent("\(profile.historyID).json"))
            defaults.set(try JSONEncoder().encode(rule), forKey: "resetRule.\(profile.historyID)")
            defaults.set(7.5, forKey: "thresholdGB.\(profile.credentialAccount)")
        }
        defaults.set(try JSONEncoder().encode(catalog), forKey: "airportCatalog.v1")
        defaults.set("gib", forKey: "trafficUnit")
        defaults.set("overview", forKey: "menuPanelLayout.v1")
        defaults.set("dark", forKey: "appearanceMode.v1")
        defaults.set(15, forKey: "intervalMinutes")
    }
    func open(_ hook: @escaping (RepositoryCheckpoint) throws -> Void = { _ in }) throws -> NativeRepository {
        try NativeRepository(root: root, defaults: defaults, services: vault.services, checkpoint: hook)
    }
    func cleanup() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    var first: AirportProfile { catalog.profiles[0] }
    @discardableResult func change(_ store: NativeRepository, mode: SubscriptionChange = .sameSource, url: String = "https://new.example/private-token") throws -> AirportProfile {
        try store.saveAirport(profile: first, name: "修改名称", plan: "新说明", subscription: url, reset: rule, threshold: 8, change: mode)
    }
    func assertOriginals() throws {
        for profile in catalog.profiles {
            #expect(try Data(contentsOf: root.appendingPathComponent("\(profile.historyID).json")) == original)
        }
        let originalCatalog = try JSONDecoder().decode(AirportCatalog.self, from: defaults.data(forKey: "airportCatalog.v1")!)
        #expect(originalCatalog.profiles.map(\.id) == catalog.profiles.map(\.id))
        #expect(originalCatalog.profiles.map(\.name) == catalog.profiles.map(\.name))
        #expect(vault.credentials["legacy-a"] == "https://a.example/old-secret")
    }
}
