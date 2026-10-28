import Foundation
import Testing
@testable import TrafficCore

@Suite
struct ObservationAnalysisTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    @Test func sharedAnalysisKeepsItsOriginalObservationsAcrossLaterSamples() throws {
        let now = date("2026-10-20T12:00:00Z")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var rule = ResetRule(); rule.kind = .monthly; rule.day = 28; rule.timeZoneID = "UTC"
        var ledger = Ledger()
        for index in 0..<4 {
            try ledger.append(Subscription(upload: 0, download: UInt64(index) * 10_000_000_000,
                                           total: 200_000_000_000),
                              at: now.addingTimeInterval(Double(index - 3) * 72 * 3600))
        }

        let analysis = ObservationAnalysis(ledger: ledger, rule: rule)
        let period = DateInterval(start: now.addingTimeInterval(-9 * 86400), end: now)
        let report = analysis.usageReport(in: period, calendar: calendar)
        #expect(report.summary.bytes == 30_000_000_000)
        #expect(report.unallocated.count == 3)
        #expect(report.daily.allSatisfy { $0.bytes == nil })

        let displayed = analysis.forecast(at: now, intervalMinutes: 4320, calendar: calendar, mode: .samplingSnapshot)
        let notification = analysis.forecast(at: now, intervalMinutes: 4320, calendar: calendar)
        #expect(displayed.sampleCount == 4)
        #expect(displayed.estimate != nil)
        #expect(notification.estimate == nil)
        let trend = analysis.balanceTrend(at: now, intervalMinutes: 4320, calendar: calendar)
        #expect(trend.recorded.flatMap { $0 }.count == 3)
        #expect(trend.forecast.estimate == nil)

        try ledger.append(Subscription(upload: 0, download: 40_000_000_000, total: 200_000_000_000),
                          at: now.addingTimeInterval(72 * 3600))
        #expect(analysis.intervals.count == 3)
        #expect(analysis.usageReport(in: period, calendar: calendar).summary.bytes == 30_000_000_000)
        let updated = ObservationAnalysis(ledger: ledger, rule: rule)
        #expect(updated.intervals.count == 4)
        #expect(updated.forecast(at: now.addingTimeInterval(72 * 3600), intervalMinutes: 4320,
                                 calendar: calendar, mode: .samplingSnapshot).sampleCount == 5)
    }

    @Test func sameObservationsRespectEachRequestedStatisticsTimeZone() throws {
        let start = date("2026-10-19T23:30:00Z"), end = date("2026-10-20T00:30:00Z")
        var ledger = Ledger()
        try ledger.append(Subscription(upload: 0, download: 10, total: 100), at: start)
        try ledger.append(Subscription(upload: 0, download: 20, total: 100), at: end)
        let analysis = ObservationAnalysis(ledger: ledger, rule: ResetRule())
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var shanghai = Calendar(identifier: .gregorian); shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let period = DateInterval(start: start, end: end)

        let utcReport = analysis.usageReport(in: period, calendar: utc)
        #expect(utcReport.summary.bytes == 10)
        #expect(utcReport.unallocated.count == 1)
        #expect(utcReport.daily.allSatisfy { $0.bytes == nil })
        let shanghaiReport = analysis.usageReport(in: period, calendar: shanghai)
        #expect(shanghaiReport.summary.bytes == 10)
        #expect(shanghaiReport.unallocated.isEmpty)
        #expect(shanghaiReport.daily.map(\.bytes) == [10])
    }
}
