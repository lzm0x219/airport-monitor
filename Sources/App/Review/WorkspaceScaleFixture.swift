import Foundation

/// Explicit, bounded synthetic input for the real native workspace. This is not
/// a render benchmark and never opens a production directory or credential store.
@MainActor
enum WorkspaceScaleFixture {
    struct Configuration: Encodable {
        let airports = 100
        let days: Int
        let samplesPerDay: Int
        init(arguments: [String]) throws {
            days = try Self.integer("--workspace-review-days", in: arguments, fallback: 8, range: 1...365)
            samplesPerDay = try Self.integer("--workspace-review-samples-per-day", in: arguments, fallback: 24, range: 1...48)
            guard airports * days * samplesPerDay <= 250_000 else {
                throw ConfigurationError("规模超出隔离夹具上限：机场数 × 天数 × 每日读数不得超过 250000。")
            }
        }
        private static func integer(_ flag: String, in arguments: [String], fallback: Int, range: ClosedRange<Int>) throws -> Int {
            guard let index = arguments.firstIndex(of: flag) else { return fallback }
            guard arguments.indices.contains(index + 1), let value = Int(arguments[index + 1]), range.contains(value) else {
                throw ConfigurationError("\(flag) 需要 \(range.lowerBound)–\(range.upperBound) 范围内的整数。")
            }
            return value
        }
    }
    struct ConfigurationError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
    struct Result {
        let snapshot: NativeSnapshot
        let credentials: [String: String]
        let usedByHost: [String: UInt64]
        let samples: Int
        let longNames: Int
        let paused: Int
        let failureTargets: Int
        let insufficientHistory: Int
    }
    struct TimingReport: Encodable {
        let kind = "isolated-workspace-fixture-and-model-load"
        let schema = 1
        let generatedAt: Date
        let configuration: Configuration
        let samples: Int
        let longNames: Int
        let paused: Int
        let failureTargets: Int
        let insufficientHistory: Int
        let stateBytes: Int
        let generationMilliseconds: Double
        let encodeAndWriteMilliseconds: Double
        let modelLoadMilliseconds: Double
        let fixtureRoot: String
        let realNotificationRequests = 0
        let scope = "Synthetic generation, encoding/write and production repository/model loading only. Excludes window creation, first draw, frame time, scrolling and navigation. No automatic sync requests."
    }

    static func generate(configuration: Configuration, now: Date) throws -> Result {
        var profiles: [AirportProfile] = []
        var sources: [SourceRecord] = []
        var credentials: [String: String] = [:]
        var usedByHost: [String: UInt64] = [:]
        var samples = 0, longNames = 0, paused = 0, failureTargets = 0, insufficient = 0
        let calendar = Calendar.current
        var rule = ResetRule(); rule.kind = .monthly
        rule.day = calendar.component(.day, from: now.addingTimeInterval(7 * 86400))
        let spacing = 86400 / Double(configuration.samplesPerDay)
        for index in 0..<configuration.airports {
            let scenario = index % 10
            let isFailure = scenario == 1, isShort = scenario == 2, isPaused = scenario == 3
            let number = String(format: "%03d", index + 1)
            let name: String
            if index == 0 { name = "云海机场 · 001" }
            else if isFailure { name = "星河 \(number) · 国际专线与超长机场名称、同步失败后的旧读数检查" }
            else if isShort { name = "轻旅 \(number) · 新添加" }
            else if isPaused { name = "备用 \(number) · 已暂停" }
            else { name = "机场 \(number)" }
            let profile = AirportProfile(id: UUID(), historyID: UUID().uuidString,
                credentialAccount: "isolated-review-\(UUID().uuidString)", name: name,
                plan: "合成月付 · 200 GB", enabled: !isPaused, archived: false)
            let host = "review-\(index).example.invalid"
            credentials[profile.credentialAccount] = "https://\(host)/\(isFailure ? "failure" : "subscription")"
            var ledger = Ledger()
            let count = isShort ? 1 : configuration.days * configuration.samplesPerDay
            for offset in 0..<count {
                let date = now.addingTimeInterval(Double(offset - count + 1) * spacing - 30)
                // Bounded synthetic 28-day counter cycles keep large fixtures
                // realistic without assigning hundreds of GB of daily traffic.
                let cycleOffset = offset % (28 * configuration.samplesPerDay)
                let dailyGrowth: UInt64 = isFailure ? 1_200_000_000 : 3_000_000_000
                let used = (isFailure ? UInt64(150_000_000_000) : UInt64(30_000_000_000))
                    + UInt64(cycleOffset) * dailyGrowth / UInt64(configuration.samplesPerDay)
                try ledger.append(Subscription(upload: 2_000_000_000, download: used,
                    total: 200_000_000_000, expiry: now.addingTimeInterval(Double(isFailure ? 2 : 20) * 86400)), at: date)
                usedByHost[host] = used
            }
            let last = ledger.samples.last!
            var attempts = [SyncAttempt(date: last.date, subscription: last.subscription, message: nil)]
            if isFailure {
                attempts.insert(SyncAttempt(date: now.addingTimeInterval(-10), subscription: nil,
                    message: TrafficError.network(-1009).localizedDescription), at: 0)
            }
            var source = SourceRecord(id: profile.historyID, airportID: profile.id,
                credentialReference: profile.credentialAccount, createdAt: ledger.samples.first!.date,
                ledger: ledger, syncAttempts: attempts,
                resetRevisions: [ResetRevision(effectiveAt: nil, rule: rule)], threshold: 10)
            source.reminderPreferences = ReminderPreferences()
            source.airportRemindersEnabled = true
            source.needsVerification = false
            profiles.append(profile); sources.append(source); samples += count
            if isFailure { longNames += 1; failureTargets += 1 }
            if isShort { insufficient += 1 }
            if isPaused { paused += 1 }
        }
        let zone = TimeZone.current.identifier
        let snapshot = NativeSnapshot(catalog: AirportCatalog(version: 2, profiles: profiles, menuAirport: profiles.first?.id),
            sources: sources, statisticsTimeZone: zone,
            migration: MigrationReport(createdAt: now, statisticsTimeZone: zone, profiles: profiles.count,
                samples: samples, files: [], warnings: ["隔离合成夹具；不是从用户数据执行的迁移。"] ))
        try snapshot.validate()
        return Result(snapshot: snapshot, credentials: credentials, usedByHost: usedByHost, samples: samples,
            longNames: longNames, paused: paused, failureTargets: failureTargets, insufficientHistory: insufficient)
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
    }
}
