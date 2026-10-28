import XCTest
@testable import TrafficCore

final class UsageStatisticsTests: XCTestCase {
    private func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func info(_ used: UInt64, upload: UInt64 = 0, total: UInt64 = 10_000) throws -> Subscription {
        try Subscription(upload: upload, download: used, total: total)
    }

    func testCycleFilterUsesExactResetInstantAcrossTimeZones() throws {
        var rule = ResetRule()
        rule.kind = .monthly; rule.day = 20; rule.hour = 9; rule.timeZoneID = "Asia/Shanghai"
        let now = date("2026-10-24T12:00:00+08:00")
        let period = try XCTUnwrap(UsageStatisticsRange.cycle.period(at: now, calendar: calendar("America/Los_Angeles"), rule: rule))
        XCTAssertEqual(period.start, date("2026-10-20T09:00:00+08:00"))
        XCTAssertEqual(period.end, now)
        var ledger = Ledger()
        try ledger.append(info(10), at: period.start.addingTimeInterval(-3600))
        try ledger.append(info(20), at: period.start.addingTimeInterval(3600))
        try ledger.append(info(30), at: period.start.addingTimeInterval(7200))
        let report = ledger.usageReport(in: period, calendar: calendar(), rule: rule)
        XCTAssertEqual(report.bytes, 10)
        XCTAssertEqual(report.excluded.count, 1)
    }

    func testUnknownCycleDoesNotFallBackToWeekAndBoundaryIsEmpty() throws {
        let now = date("2026-10-24T12:00:00Z")
        XCTAssertNil(UsageStatisticsRange.cycle.period(at: now, calendar: calendar(), rule: ResetRule()))
        var once = ResetRule(); once.kind = .once; once.anchor = now.addingTimeInterval(3600)
        XCTAssertNil(UsageStatisticsRange.cycle.period(at: now, calendar: calendar(), rule: once))
        once.anchor = now
        XCTAssertEqual(UsageStatisticsRange.cycle.period(at: now, calendar: calendar(), rule: once)?.duration, 0)
    }

    func testWeekFilterIncludesSevenNaturalDaysAcrossDST() throws {
        let cal = calendar("America/Los_Angeles")
        let period = try XCTUnwrap(UsageStatisticsRange.week.period(at: date("2026-11-03T12:00:00-08:00"), calendar: cal, rule: ResetRule()))
        XCTAssertEqual(cal.dateComponents([.day], from: period.start, to: period.end).day, 7)
        XCTAssertEqual(period.duration, 7 * 86400 + 3600)
    }

    func testCrossDayRecoveryRemainsUnallocatedAndPartialFilterNeverProrates() throws {
        var ledger = Ledger()
        let start = date("2026-10-19T22:00:00+08:00"), end = date("2026-10-21T08:00:00+08:00")
        try ledger.append(info(80), at: start)
        try ledger.append(info(86), at: end)
        let all = ledger.usageReport(in: DateInterval(start: start, end: end), calendar: calendar())
        XCTAssertEqual(all.summary.bytes, 6)
        XCTAssertEqual(all.unallocatedBytes, 6)
        XCTAssertEqual(all.unallocated.count, 1)
        XCTAssertTrue(all.daily.allSatisfy { $0.bytes == nil && $0.hasUnallocated })
        let middle = ledger.usageReport(in: calendar().dateInterval(of: .day, for: start.addingTimeInterval(86400))!, calendar: calendar())
        XCTAssertNil(middle.bytes)
        XCTAssertEqual(middle.partial.count, 1)
        XCTAssertTrue(middle.unallocated.isEmpty)
        XCTAssertEqual(middle.daily.first?.hasUnallocated, true)
    }

    func testMidnightEndpointBelongsToPreviousDayOnly() throws {
        var ledger = Ledger()
        let start = date("2026-10-19T23:00:00+08:00"), midnight = date("2026-10-20T00:00:00+08:00")
        try ledger.append(info(80), at: start)
        try ledger.append(info(86), at: midnight)
        let first = ledger.usageReport(in: calendar().dateInterval(of: .day, for: start)!, calendar: calendar())
        let next = ledger.usageReport(in: calendar().dateInterval(of: .day, for: midnight)!, calendar: calendar())
        XCTAssertEqual(first.daily.first?.bytes, 6)
        XCTAssertEqual(first.summary.intervals, 1)
        XCTAssertTrue(first.unallocated.isEmpty)
        XCTAssertNil(next.bytes)
        XCTAssertEqual(next.summary.excludedIntervals, 0)
    }

    func testSingleBaselineMissingAndObservedZeroAreDifferent() throws {
        var ledger = Ledger()
        let start = date("2026-10-19T09:00:00+08:00")
        let period = calendar().dateInterval(of: .day, for: start)!
        XCTAssertNil(ledger.usageReport(in: period, calendar: calendar()).daily.first?.bytes)
        try ledger.append(info(80), at: start)
        let baseline = ledger.usageReport(in: period, calendar: calendar())
        XCTAssertNil(baseline.bytes)
        XCTAssertEqual(baseline.observedStart, start)
        try ledger.append(info(80), at: start.addingTimeInterval(3600))
        let zero = ledger.usageReport(in: period, calendar: calendar())
        XCTAssertEqual(zero.bytes, 0)
        XCTAssertEqual(zero.daily.first?.bytes, 0)
        XCTAssertEqual(zero.summary.intervals, 1)
    }

    func testEmptyRangeAtMidnightOrWithinDayHasNoObservations() throws {
        var ledger = Ledger()
        let midnight = date("2026-10-19T00:00:00+08:00")
        try ledger.append(info(80), at: midnight)
        try ledger.append(info(86), at: midnight.addingTimeInterval(3600))
        let original = ledger.observedIntervals(rule: ResetRule())
        for instant in [midnight, midnight.addingTimeInterval(1800)] {
            let report = ledger.usageReport(in: DateInterval(start: instant, duration: 0), calendar: calendar())
            XCTAssertTrue(report.daily.isEmpty)
            XCTAssertNil(report.bytes)
            XCTAssertEqual(report.summary.intervals, 0)
            XCTAssertEqual(report.summary.excludedIntervals, 0)
            XCTAssertTrue(report.unallocated.isEmpty)
            XCTAssertTrue(report.excluded.isEmpty)
            XCTAssertTrue(report.partial.isEmpty)
            XCTAssertNil(report.observedStart)
            XCTAssertNil(report.observedEnd)
        }
        XCTAssertEqual(ledger.observedIntervals(rule: ResetRule()), original)
    }

    func testComponentRollbackCannotBeHiddenByOtherComponentGrowth() throws {
        var ledger = Ledger()
        let start = date("2026-10-19T09:00:00Z")
        try ledger.append(info(70, upload: 10), at: start)
        try ledger.append(info(75, upload: 8), at: start.addingTimeInterval(60))
        let interval = try XCTUnwrap(ledger.observedIntervals(rule: ResetRule()).first)
        XCTAssertEqual(interval.reason, .counterRollback)
        XCTAssertNil(interval.bytes)
    }

    func testQuotaChangeAndScheduledResetExcludeEvenIncreasingCounters() throws {
        var ledger = Ledger()
        let start = date("2026-10-19T09:00:00Z")
        try ledger.append(info(80, total: 100), at: start)
        try ledger.append(info(80, total: 150), at: start.addingTimeInterval(60))
        try ledger.append(info(86, total: 150), at: start.addingTimeInterval(120))
        var rule = ResetRule(); rule.kind = .once; rule.anchor = start.addingTimeInterval(90)
        let intervals = ledger.observedIntervals(rule: rule)
        XCTAssertEqual(intervals.map(\.reason), [.quotaChanged, .knownReset])
        XCTAssertTrue(intervals.allSatisfy { $0.bytes == nil })
        rule.anchor = start.addingTimeInterval(60)
        XCTAssertEqual(ledger.observedIntervals(rule: rule).last?.reason, .comparable)
    }

    func testRuleRevisionDoesNotReclassifyPreviousHistory() throws {
        var ledger = Ledger()
        let start = date("2026-10-19T09:00:00Z")
        for i in 0...4 { try ledger.append(info(UInt64(80 + i)), at: start.addingTimeInterval(Double(i) * 3600)) }
        var old = ResetRule(); old.kind = .once; old.anchor = start.addingTimeInterval(1800)
        var newer = ResetRule(); newer.kind = .once; newer.anchor = start.addingTimeInterval(12600)
        let revisions = [StatisticsRuleRevision(effectiveAt: nil, rule: old),
                         StatisticsRuleRevision(effectiveAt: start.addingTimeInterval(7200), rule: newer)]
        let intervals = ledger.observedIntervals(rule: newer, revisions: revisions)
        XCTAssertEqual(intervals.map(\.reason), [.knownReset, .comparable, .comparable, .knownReset])
        XCTAssertEqual(intervals[2].bytes, 1)
        XCTAssertEqual(ledger.samples.count, 5)
    }

    func testRuleEffectiveEndpointsPreserveCompletedIntervalsAndApplyNewRuleForward() throws {
        var ledger = Ledger()
        let start = date("2026-10-19T09:00:00Z")
        for i in 0...3 { try ledger.append(info(UInt64(80 + i)), at: start.addingTimeInterval(Double(i) * 3600)) }
        var newRule = ResetRule(); newRule.kind = .once; newRule.anchor = start.addingTimeInterval(5400)
        let revisions = [StatisticsRuleRevision(effectiveAt: nil, rule: ResetRule()),
                         StatisticsRuleRevision(effectiveAt: start.addingTimeInterval(3600), rule: newRule),
                         StatisticsRuleRevision(effectiveAt: start.addingTimeInterval(9000), rule: ResetRule())]
        let intervals = ledger.observedIntervals(rule: ResetRule(), revisions: revisions)
        // End == edit: preserve the completed old interval. Start == edit: use the new reset rule.
        // Edit strictly inside the final interval: comparison is not attributable to one rule.
        XCTAssertEqual(intervals.map(\.reason), [.comparable, .knownReset, .ruleChanged])
        XCTAssertEqual(intervals.first?.bytes, 1)
        XCTAssertNil(intervals[1].bytes)
        XCTAssertNil(intervals[2].bytes)
    }

    func testRuleWithOnlyDatedRevisionDoesNotApplyBeforeItExisted() throws {
        var ledger = Ledger()
        let start = date("2026-10-19T09:00:00Z")
        try ledger.append(info(80), at: start)
        try ledger.append(info(86), at: start.addingTimeInterval(3600))
        var rule = ResetRule(); rule.kind = .once; rule.anchor = start.addingTimeInterval(1800)
        XCTAssertEqual(ledger.observedIntervals(rule: rule, revisions: [
            StatisticsRuleRevision(effectiveAt: start.addingTimeInterval(7200), rule: rule)
        ]).first?.reason, .comparable)
    }

    func testDSTUsesActualCalendarDayAndFixedZone() throws {
        let cal = calendar("America/New_York")
        for (begin, finish, hours) in [("2026-03-08T00:00:00-05:00", "2026-03-09T00:00:00-04:00", 23),
                                      ("2026-11-01T00:00:00-04:00", "2026-11-02T00:00:00-05:00", 25)] {
            var ledger = Ledger()
            let start = date(begin), end = date(finish)
            try ledger.append(info(80), at: start)
            try ledger.append(info(86), at: end)
            let report = ledger.usageReport(in: DateInterval(start: start, end: end), calendar: cal)
            XCTAssertEqual(report.daily.count, 1)
            XCTAssertEqual(report.daily.first?.period.duration, Double(hours * 3600))
            XCTAssertEqual(report.daily.first?.bytes, 6)
            XCTAssertTrue(report.unallocated.isEmpty)
        }
    }

    func testRepeatedAndReversedTimesNeverCreateCountedIntervals() throws {
        var original = Ledger()
        let start = date("2026-10-19T09:00:00Z")
        for i in 0...2 { try original.append(info(UInt64(80 + i)), at: start.addingTimeInterval(Double(i) * 60)) }
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var samples = try XCTUnwrap(object["samples"] as? [[String: Any]])
        samples[1]["date"] = samples[0]["date"]
        samples[2]["date"] = start.addingTimeInterval(-60).timeIntervalSinceReferenceDate
        object["samples"] = samples
        let malformed = try JSONDecoder().decode(Ledger.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(malformed.observedIntervals(rule: ResetRule()).map(\.reason), [.invalidTime, .invalidTime])
        XCTAssertThrowsError(try malformed.validate())
        XCTAssertThrowsError(try original.append(info(99), at: start))
        XCTAssertEqual(original.samples.count, 3)
    }

    func testPersistedSamplePairIdentityAndSmallDeltaAtLargeCounterSurviveReload() throws {
        var ledger = Ledger()
        let start = date("2026-10-19T09:00:00Z"), large = UInt64.max - 100
        try ledger.append(info(large, total: 0), at: start)
        try ledger.append(info(large + 1, total: 0), at: start.addingTimeInterval(60))
        let before = ledger.observedIntervals(rule: ResetRule())
        let reloaded = try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(ledger))
        try reloaded.validate()
        XCTAssertEqual(before, reloaded.observedIntervals(rule: ResetRule()))
        XCTAssertEqual(before.first?.bytes, 1)
    }
}
