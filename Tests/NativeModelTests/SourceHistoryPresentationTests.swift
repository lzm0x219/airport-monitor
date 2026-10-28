import Foundation
import Testing
import TrafficCore
@testable import NativeModels

@Suite struct SourceHistoryPresentationTests {
    private var calendar: Calendar {
        var result = Calendar(identifier: .iso8601)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func source(_ readings: [(String, UInt64)]) throws -> SourceRecord {
        var ledger = Ledger()
        for (time, used) in readings {
            try ledger.append(Subscription(upload: 0, download: used, total: 1000), at: date(time))
        }
        return SourceRecord(id: UUID().uuidString, airportID: UUID(), credentialReference: "isolated-history-test",
            createdAt: readings.first.map { date($0.0) } ?? date("2026-01-01T00:00:00Z"),
            ledger: ledger, syncAttempts: [], resetRevisions: [ResetRevision(effectiveAt: nil, rule: ResetRule())], threshold: 10)
    }
    @Test func oldSourceKeepsZeroMissingAndCrossDayDistinctWithoutMutation() throws {
        var old = try source([("2026-01-01T10:00:00Z", 100), ("2026-01-01T11:00:00Z", 100),
                              ("2026-01-03T10:00:00Z", 140)])
        old.endedAt = date("2026-01-04T00:00:00Z")
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(old)
        let report = try #require(SourceHistoryPresentation(source: old, calendar: calendar).report)
        #expect(report.bytes == 40)
        #expect(report.daily[0].bytes == 0)
        #expect(report.daily[1].bytes == nil)
        #expect(report.unallocatedBytes == 40)
        #expect(report.partial.isEmpty)
        let current = try source([("2026-01-04T10:00:00Z", 700), ("2026-01-04T11:00:00Z", 900)])
        #expect(SourceHistoryPresentation(source: current, calendar: calendar).report?.bytes == 200)
        #expect(try encoder.encode(old) == before)
    }
    @Test func historyUsesTheSourcesRuleRevisions() throws {
        var old = try source([("2026-01-01T10:00:00Z", 100), ("2026-01-02T10:00:00Z", 140)])
        var laterRule = ResetRule(); laterRule.kind = .monthly; laterRule.day = 2
        old.resetRevisions.append(ResetRevision(effectiveAt: date("2026-01-10T00:00:00Z"), rule: laterRule))
        let report = try #require(SourceHistoryPresentation(source: old, calendar: calendar).report)
        #expect(report.bytes == 40)
        #expect(report.excluded.isEmpty)
    }
    @Test func emptyAndBaselineDoNotInventUsage() throws {
        #expect(SourceHistoryPresentation(source: try source([]), calendar: calendar).report == nil)
        let baseline = try source([("2026-01-01T10:00:00Z", 100)])
        let report = try #require(SourceHistoryPresentation(source: baseline, calendar: calendar).report)
        #expect(report.bytes == nil)
        #expect(report.daily.allSatisfy { $0.bytes == nil })
        #expect(report.unallocated.isEmpty)
    }
}
