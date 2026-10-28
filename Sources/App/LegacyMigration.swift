import Foundation
import CryptoKit
#if SWIFT_PACKAGE
import TrafficCore
#endif

/// Reads and validates legacy inputs without publishing or modifying them.
@MainActor
enum LegacyMigration {
    static func legacyPreferences(_ defaults: UserDefaults) -> [String: Any] {
        defaults.dictionaryRepresentation().filter {
            ["airportCatalog.v1", "profileID", "intervalMinutes", "remindersEnabled", "thresholdGB", "trafficUnit", "menuDisplay", "appearanceMode.v1", "menuPanelLayout.v1"].contains($0.key) ||
            $0.key.hasPrefix("historyProfile.") || $0.key.hasPrefix("resetRule.") || $0.key.hasPrefix("thresholdGB.")
        }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func migrate(root: URL, defaults: UserDefaults, services: MonitorServices) throws -> NativeSnapshot {
        let now = services.now(), zone = TimeZone.current.identifier
        var catalog: AirportCatalog
        if let data = defaults.data(forKey: "airportCatalog.v1") {
            catalog = try JSONDecoder().decode(AirportCatalog.self, from: data)
            guard catalog.version == 1 else { throw TrafficError.storage }
            try catalog.validate()
        } else {
            let id = defaults.string(forKey: "historyProfile.active-url") ?? defaults.string(forKey: "profileID")
            let hasSecret = try services.readCredential("active-url") != nil
            if hasSecret || id.map({ FileManager.default.fileExists(atPath: root.appendingPathComponent("\($0).json").path) }) == true {
                let profile = AirportProfile(id: UUID(), historyID: id ?? UUID().uuidString, credentialAccount: "active-url",
                                             name: "我的机场", plan: "", enabled: true, archived: false)
                catalog = AirportCatalog(profiles: [profile], menuAirport: profile.id)
            } else { catalog = AirportCatalog(profiles: [], menuAirport: nil) }
        }
        catalog.version = 2
        for index in catalog.profiles.indices {
            let profile = catalog.profiles[index]
            if let currentID = defaults.string(forKey: "historyProfile.\(profile.credentialAccount)") { catalog.profiles[index].historyID = currentID }
        }
        try catalog.validate()
        if !catalog.profiles.contains(where: { $0.id == catalog.menuAirport && !$0.archived }) {
            catalog.menuAirport = catalog.profiles.first(where: { !$0.archived })?.id
        }
        var sources: [SourceRecord] = [], files: [LegacyFileRecord] = [], warnings: [String] = []
        var observedFiles: [String: Data] = [:]
        for profile in catalog.profiles {
            let url = root.appendingPathComponent("\(profile.historyID).json")
            var ledger = Ledger(), attempts: [SyncAttempt] = []
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url); observedFiles[url.lastPathComponent] = data
                ledger = try JSONDecoder().decode(Ledger.self, from: data); try ledger.validate()
            } else { warnings.append("未找到旧账本：\(profile.historyID).json，未补造历史。") }
            let logURL = url.appendingPathExtension("sync")
            if FileManager.default.fileExists(atPath: logURL.path) {
                let data = try Data(contentsOf: logURL); observedFiles[logURL.lastPathComponent] = data
                attempts = try JSONDecoder().decode([SyncAttempt].self, from: data)
            }
            var rule = ResetRule()
            if let data = defaults.data(forKey: "resetRule.\(profile.historyID)") {
                rule = try JSONDecoder().decode(ResetRule.self, from: data); try rule.validate()
            }
            let oldThreshold = defaults.object(forKey: "thresholdGB.\(profile.credentialAccount)") as? Double ?? defaults.double(forKey: "thresholdGB")
            let threshold = oldThreshold == 0 ? 10 : oldThreshold
            sources.append(SourceRecord(id: profile.historyID, airportID: profile.id, credentialReference: profile.credentialAccount,
                createdAt: ledger.samples.first?.date ?? now, ledger: ledger, syncAttempts: attempts,
                resetRevisions: [ResetRevision(effectiveAt: nil, rule: rule)], threshold: threshold,
                migratedNotificationAt: ledger.lowBalanceNotified ? now : nil))
        }
        if FileManager.default.fileExists(atPath: root.path) {
            for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = url.lastPathComponent
                let id = name.components(separatedBy: ".")[0]
                guard UUID(uuidString: id) != nil, name.hasSuffix(".json") || name.hasSuffix(".json.sync") else { continue }
                let data = try Data(contentsOf: url)
                if let observed = observedFiles[name], observed != data { throw TrafficError.storage }
                let associated = catalog.profiles.contains { $0.historyID == id }
                let ledger = name.hasSuffix(".json") ? try? JSONDecoder().decode(Ledger.self, from: data) : nil
                files.append(LegacyFileRecord(name: name, sha256: digest(data),
                                              samples: ledger?.samples.count, associated: associated))
                if !associated { warnings.append("未关联历史：\(name)，保留原文件，不自动归属。") }
            }
        }
        return NativeSnapshot(catalog: catalog, sources: sources, statisticsTimeZone: zone,
            migration: MigrationReport(createdAt: now, statisticsTimeZone: zone, profiles: catalog.profiles.count,
                samples: sources.reduce(0) { $0 + $1.ledger.samples.count }, files: files,
                warnings: warnings + ["统计时区记录为迁移时系统时区；旧规则的实际生效时间未知。", "原始账本与旧偏好保留；回退旧版不包含迁移后的新记录。"]))
    }
}
