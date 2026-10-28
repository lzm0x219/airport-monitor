import Foundation

public struct Sample: Codable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let subscription: Subscription
    public let reset: Bool
}

public struct UsageSummary: Sendable {
    public let bytes: Double
    public let intervals: Int
    public let excludedIntervals: Int
    public var text: String { intervals == 0 ? "暂无完整区间" : String(format: "≥ %.2f GB", bytes / 1_000_000_000) }
}

public struct Ledger: Codable, Sendable {
    public var version = 1
    public private(set) var samples: [Sample] = []
    public var lowBalanceNotified = false
    public init() {}

    @discardableResult
    public mutating func append(_ subscription: Subscription, at date: Date = Date()) throws -> Bool {
        if let previous = samples.last, date <= previous.date { throw TrafficError.clock }
        let reset = samples.last.map {
            subscription.upload < $0.subscription.upload || subscription.download < $0.subscription.download
        } ?? false
        samples.append(Sample(id: UUID(), date: date, subscription: subscription, reset: reset))
        if reset { lowBalanceNotified = false }
        return reset
    }

    /// Count only intervals wholly inside the requested calendar period.
    /// Reset intervals are unknowable and excluded, never turned into negative usage.
    public func usage(in period: DateInterval, resetRule: ResetRule? = nil) -> UsageSummary {
        usageReport(in: period, calendar: resetRule?.calendar ?? Calendar.current,
                    rule: resetRule ?? ResetRule()).summary
    }

    public func validate() throws {
        guard version == 1, Set(samples.map(\.id)).count == samples.count else { throw TrafficError.storage }
        for (index, sample) in samples.enumerated() {
            _ = try Subscription(upload: sample.subscription.upload, download: sample.subscription.download,
                                 total: sample.subscription.total, expiry: sample.subscription.expiry)
            if index > 0 {
                let previous = samples[index - 1]
                let reset = sample.subscription.upload < previous.subscription.upload || sample.subscription.download < previous.subscription.download
                guard sample.date > previous.date, sample.reset == reset else { throw TrafficError.storage }
            }
        }
    }
}

public struct HistoryStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> Ledger {
        guard FileManager.default.fileExists(atPath: url.path) else { return Ledger() }
        let ledger = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: url))
        try ledger.validate()
        return ledger
    }
    public func save(_ ledger: Ledger) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ledger).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func quarantine() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("\(UUID().uuidString).corrupt"))
        }
    }
}
