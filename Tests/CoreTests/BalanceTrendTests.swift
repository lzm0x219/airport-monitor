import XCTest
@testable import TrafficCore

final class BalanceTrendTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-17T12:00:00Z")!
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private var schedule: ResetRule {
        var rule = ResetRule(); rule.kind = .monthly; rule.day = 1; rule.timeZoneID = "UTC"
        return rule
    }
    private func append(_ ledger: inout Ledger, used: UInt64, at date: Date, total: UInt64 = 100_000_000_000) throws {
        try ledger.append(Subscription(upload: 0, download: used, total: total), at: date)
    }
    private func history(zero: Bool = false, total: UInt64 = 100_000_000_000) throws -> Ledger {
        var ledger = Ledger()
        for hour in 0...132 {
            try append(&ledger, used: zero ? 0 : UInt64(hour) * 100_000_000,
                       at: now.addingTimeInterval(Double(hour - 132) * 3600), total: total)
        }
        return ledger
    }
    func testInsufficientHistoryRetainsActualBalanceWithoutProjection() throws {
        var ledger = Ledger()
        try append(&ledger, used: 10_000_000_000, at: now.addingTimeInterval(-300))
        try append(&ledger, used: 11_000_000_000, at: now)
        let trend = ledger.balanceTrend(at: now, rule: ResetRule(), intervalMinutes: 5, calendar: calendar)
        XCTAssertEqual(trend.forecast.reason, .insufficient)
        XCTAssertTrue(trend.projected.isEmpty)
        XCTAssertEqual(trend.recorded.flatMap { $0 }.map(\.bytes), [90_000_000_000, 89_000_000_000])
        XCTAssertEqual(trend.end, now)
    }
    func testGapsCounterResetsPlanChangesAndScheduledResetsStayDisconnected() throws {
        var ledger = Ledger()
        try append(&ledger, used: 100, at: now.addingTimeInterval(-1800))
        try append(&ledger, used: 200, at: now.addingTimeInterval(-1500))
        try append(&ledger, used: 300, at: now.addingTimeInterval(-600)) // gap > 2 periods
        try append(&ledger, used: 0, at: now.addingTimeInterval(-300)) // reset
        try append(&ledger, used: 100, at: now, total: 200_000_000_000) // plan change
        let trend = ledger.balanceTrend(at: now, rule: ResetRule(), intervalMinutes: 5, calendar: calendar)
        XCTAssertEqual(trend.recorded.map(\.count), [2, 1, 1, 1])

        var schedule = ResetRule(); schedule.kind = .once
        schedule.anchor = now.addingTimeInterval(-1650)
        let reset = ledger.balanceTrend(at: now, rule: schedule, intervalMinutes: 5, calendar: calendar)
        XCTAssertEqual(reset.recorded.first?.count, 1)
    }
    func testProjectionUsesActualRateAndStopsAtEarlierReset() throws {
        let ledger = try history()
        var schedule = ResetRule(); schedule.kind = .monthly; schedule.day = 20; schedule.timeZoneID = "UTC"
        let trend = ledger.balanceTrend(at: now, rule: schedule, intervalMinutes: 60, calendar: calendar)
        let estimate = try XCTUnwrap(trend.forecast.estimate)
        XCTAssertEqual(trend.projected.count, 2)
        XCTAssertEqual(trend.projected.first?.date, now)
        XCTAssertEqual(trend.projected.first?.bytes, 86_800_000_000)
        XCTAssertEqual(trend.projected.last?.date, estimate.boundary)
        XCTAssertEqual(try XCTUnwrap(trend.projected.last?.bytes), 80_800_000_000, accuracy: 1)
    }
    func testLongForecastIsClippedToSevenDaysAndPausedForecastHasNoDashes() throws {
        let ledger = try history()
        let trend = ledger.balanceTrend(at: now, rule: schedule, intervalMinutes: 60, calendar: calendar)
        XCTAssertEqual(trend.end, now.addingTimeInterval(7 * 86400))
        XCTAssertEqual(try XCTUnwrap(trend.projected.last?.bytes), 70_000_000_000, accuracy: 1)
        let stale = ledger.balanceTrend(at: now, rule: schedule, intervalMinutes: 60,
                                       calendar: calendar, synchronizationFailed: true)
        XCTAssertTrue(stale.projected.isEmpty)
        XCTAssertEqual(stale.recorded.flatMap { $0 }.count, ledger.samples.count)
    }
    func testZeroUsageHasNoForecastAndSingleSampleHasNoInventedLine() throws {
        let zero = try history(zero: true).balanceTrend(at: now, rule: schedule, intervalMinutes: 60, calendar: calendar)
        XCTAssertTrue(zero.projected.isEmpty)
        XCTAssertEqual(zero.forecast.diagnostic, .zeroGrowth)
        XCTAssertGreaterThan(zero.upperBytes, zero.lowerBytes)
        var single = Ledger(); try append(&single, used: 0, at: now)
        let trend = single.balanceTrend(at: now, rule: ResetRule(), intervalMinutes: 5, calendar: calendar)
        XCTAssertEqual(trend.recorded.map(\.count), [1])
        XCTAssertTrue(trend.projected.isEmpty)
    }
    func testProjectionStopsAtExhaustionAndNeverGoesNegative() throws {
        let ledger = try history(total: 20_000_000_000)
        let trend = ledger.balanceTrend(at: now, rule: schedule, intervalMinutes: 60, calendar: calendar)
        XCTAssertEqual(trend.end, trend.forecast.estimate?.exhaustion)
        XCTAssertLessThan(trend.end, now.addingTimeInterval(7 * 86400))
        XCTAssertEqual(try XCTUnwrap(trend.projected.last?.bytes), 0, accuracy: 1)
    }

    func testDailyReadingsCanSupportForecastWithoutInventingContinuousRecordedLine() throws {
        var ledger = Ledger()
        for day in -4...0 {
            try append(&ledger, used: UInt64(day + 4) * 1_000_000_000,
                       at: now.addingTimeInterval(Double(day) * 86400))
        }
        let trend = ledger.balanceTrend(at: now, rule: schedule, intervalMinutes: 5, calendar: calendar)
        XCTAssertEqual(trend.recorded.map(\.count), [1, 1, 1, 1, 1])
        XCTAssertEqual(trend.projected.count, 2)
        XCTAssertEqual(try XCTUnwrap(trend.forecast.estimate?.dailyBytes), 1_000_000_000, accuracy: 0.001)
        let paused = ledger.balanceTrend(at: now, rule: schedule, intervalMinutes: 5,
                                         calendar: calendar, availability: .init(paused: true))
        XCTAssertTrue(paused.projected.isEmpty)
        XCTAssertEqual(paused.recorded, trend.recorded)
    }

    func testRuleChangeBreaksRecordedLineAndForecastAtSameInterval() throws {
        let ledger = try history()
        let revisions = [StatisticsRuleRevision(effectiveAt: nil, rule: schedule),
                         StatisticsRuleRevision(effectiveAt: now.addingTimeInterval(-1800), rule: schedule)]
        let trend = ledger.balanceTrend(at: now, rule: schedule, intervalMinutes: 60,
                                        calendar: calendar, revisions: revisions)
        XCTAssertEqual(trend.recorded.last?.count, 1)
        XCTAssertEqual(trend.forecast.sampleCount, 1)
        XCTAssertTrue(trend.projected.isEmpty)
    }

    func testProjectionRemainsAnchoredToLastReadingWhileFresh() throws {
        let ledger = try history()
        let original = ledger.balanceTrend(at: now, rule: schedule, intervalMinutes: 5, calendar: calendar)
        let later = ledger.balanceTrend(at: now.addingTimeInterval(20 * 60), rule: schedule, intervalMinutes: 5, calendar: calendar)
        XCTAssertEqual(original.projected, later.projected)
        XCTAssertEqual(later.projected.first?.date, now)
        XCTAssertEqual(later.projected.first?.bytes, ledger.samples.last?.subscription.remaining.map { Double($0) })
    }
}
