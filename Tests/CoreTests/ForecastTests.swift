import XCTest
@testable import TrafficCore

final class ForecastTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!; return cal
    }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private var now: Date { date("2026-10-17T12:00:00Z") }
    private func rule(_ kind: ResetKind = .monthly, day: Int = 1) -> ResetRule {
        var rule = ResetRule(); rule.kind = kind; rule.day = day; rule.timeZoneID = "UTC"; return rule
    }
    private func history(zero: Bool = false, sparse: Bool = false, rollbackHour: Int? = nil,
                         expiry: Date? = nil) throws -> Ledger {
        var ledger = Ledger()
        let start = date("2026-10-12T00:00:00Z")
        for hour in 0...132 {
            if sparse && hour % 24 != 0 && hour != 132 { continue }
            let counter = rollbackHour.map { hour >= $0 ? hour - $0 : hour } ?? hour
            try ledger.append(Subscription(upload: 0, download: zero ? 0 : UInt64(counter) * 100_000_000,
                                           total: 100_000_000_000, expiry: expiry),
                              at: start.addingTimeInterval(Double(hour) * 3600))
        }
        return ledger
    }
    func testMonthEndClampsWithoutDriftingAndLeapYear() {
        let schedule = rule(day: 31)
        XCTAssertEqual(schedule.window(at: date("2024-02-01T00:00:00Z")).next, date("2024-02-29T00:00:00Z"))
        XCTAssertEqual(schedule.window(at: date("2024-03-01T00:00:00Z")).next, date("2024-03-31T00:00:00Z"))
        XCTAssertEqual(schedule.window(at: date("2026-02-01T00:00:00Z")).next, date("2026-02-28T00:00:00Z"))
    }
    func testIntervalCheckerMatchesDirectRuleAcrossBoundariesAndRewinds() {
        for kind in ResetKind.allCases {
            var schedule = rule(kind, day: 8)
            schedule.timeZoneID = "America/New_York"
            schedule.hour = 2; schedule.minute = 30
            schedule.anchor = date("2026-03-08T07:30:00Z")
            var checker = ResetIntervalChecker(rule: schedule)
            let starts = ["2026-03-07T00:00:00Z", "2026-03-08T06:59:00Z", "2026-03-08T07:00:00Z", "2026-03-08T07:30:00Z", "2026-03-09T00:00:00Z", "2026-05-01T00:00:00Z", "2026-03-08T06:59:00Z"]
            for text in starts {
                let before = date(text)
                for gap in [60.0, 7200, 5_000_000] {
                    let after = before.addingTimeInterval(gap)
                    XCTAssertEqual(checker.crosses(before, after), schedule.crosses(before, after), "\(kind) \(text), gap \(gap)")
                }
            }
        }
    }
    func testBillingAnchorAndOneTimeDoNotInventRecurrence() {
        var billing = rule(.billing); billing.anchor = date("2026-12-31T00:00:00Z")
        XCTAssertNil(billing.window(at: now).previous)
        XCTAssertEqual(billing.window(at: now).next, billing.anchor)
        XCTAssertEqual(billing.window(at: date("2027-02-01T00:00:00Z")).next, date("2027-02-28T00:00:00Z"))
        var once = rule(.once); once.anchor = now
        XCTAssertNil(once.window(at: now).next)
        XCTAssertEqual(once.window(at: now).previous, now)
        XCTAssertNil(rule(.none).window(at: now).next)
    }
    func testScheduleTimezoneDSTAndRoundTrip() throws {
        var schedule = rule(day: 8); schedule.timeZoneID = "America/New_York"; schedule.hour = 2; schedule.minute = 30
        let reset = try XCTUnwrap(schedule.window(at: date("2026-03-01T00:00:00Z")).next)
        XCTAssertEqual(schedule.calendar.component(.day, from: reset), 8)
        XCTAssertEqual(schedule.calendar.component(.hour, from: reset), 3)
        XCTAssertEqual(try JSONDecoder().decode(ResetRule.self, from: JSONEncoder().encode(schedule)), schedule)
        schedule.timeZoneID = "invalid"; XCTAssertThrowsError(try schedule.validate())
        schedule.timeZoneID = "UTC"; schedule.day = 0; XCTAssertThrowsError(try schedule.validate())
    }
    func testKnownResetBoundaryIsExcludedFromDailyUsage() throws {
        var ledger = Ledger()
        let start = date("2026-10-01T00:00:00Z")
        try ledger.append(Subscription(upload: 0, download: 100, total: 1000), at: start.addingTimeInterval(-60))
        try ledger.append(Subscription(upload: 0, download: 150, total: 1000), at: start.addingTimeInterval(60))
        let period = DateInterval(start: start.addingTimeInterval(-3600), duration: 7200)
        XCTAssertEqual(ledger.usage(in: period).bytes, 50)
        XCTAssertEqual(ledger.usage(in: period, resetRule: rule()).bytes, 0)
        XCTAssertEqual(ledger.usage(in: period, resetRule: rule()).excludedIntervals, 1)
    }
    func testForecastUsesActualObservationSpanAndRequiresResetBeforeExpiry() throws {
        let ledger = try history(expiry: date("2026-10-25T00:00:00Z"))
        let unavailable = ledger.forecast(at: now, rule: rule(), intervalMinutes: 60, calendar: calendar)
        XCTAssertNil(unavailable.estimate)
        XCTAssertEqual(unavailable.diagnostic, .expiryBeforeReset)
        let result = ledger.forecast(at: now, rule: rule(day: 20), intervalMinutes: 60, calendar: calendar)
        let forecast = try XCTUnwrap(result.estimate)
        XCTAssertEqual(forecast.days, 6)
        XCTAssertEqual(result.sampleCount, 133)
        XCTAssertEqual(result.observedSeconds, 132 * 3600)
        XCTAssertEqual(forecast.dailyBytes, 2_400_000_000, accuracy: 1)
        XCTAssertEqual(forecast.coverage, 1, accuracy: 0.001)
        XCTAssertEqual(forecast.boundaryKind, .reset)
        XCTAssertEqual(forecast.boundary, date("2026-10-20T00:00:00Z"))
        XCTAssertEqual(try XCTUnwrap(forecast.remainingAtBoundary), 80_800_000_000, accuracy: 1)
    }
    func testSparseAndFreshnessGuards() throws {
        XCTAssertNotNil(try history(sparse: true).forecast(at: now, rule: rule(), intervalMinutes: 60, calendar: calendar).estimate)
        let ledger = try history()
        XCTAssertNotNil(ledger.forecast(at: now.addingTimeInterval(10800), rule: rule(), intervalMinutes: 60, calendar: calendar).estimate)
        XCTAssertEqual(ledger.forecast(at: now.addingTimeInterval(10801), rule: rule(), intervalMinutes: 60, calendar: calendar).reason, .stale)
        XCTAssertEqual(ledger.forecast(at: now, rule: rule(), intervalMinutes: 60, calendar: calendar, synchronizationFailed: true).reason, .stale)
        XCTAssertEqual(ledger.forecast(at: now.addingTimeInterval(-1), rule: rule(), intervalMinutes: 60, calendar: calendar).reason, .stale)
    }
    func testPlanChangeBeginsNewForecastCycleWithoutDeletingHistory() throws {
        var ledger = try history()
        let count = ledger.samples.count
        let changed = now.addingTimeInterval(60)
        try ledger.append(Subscription(upload: 0, download: 14_000_000_000, total: 200_000_000_000), at: changed)
        let result = ledger.forecast(at: changed, rule: rule(.none), intervalMinutes: 60, calendar: calendar)
        XCTAssertEqual(result.reason, .insufficient)
        XCTAssertEqual(result.eligibleDays, 1)
        XCTAssertEqual(ledger.samples.count, count + 1)
    }
    func testMissingResetDoesNotInventADeadlineAndResetAtExactBoundary() throws {
        let ledger = try history()
        let result = ledger.forecast(at: now, rule: rule(.none), intervalMinutes: 60, calendar: calendar)
        XCTAssertNil(result.estimate)
        XCTAssertEqual(result.diagnostic, .missingReset)
        let boundary = date("2026-11-01T00:00:00Z")
        let window = rule().window(at: boundary)
        XCTAssertEqual(window.previous, boundary)
        XCTAssertEqual(window.next, date("2026-12-01T00:00:00Z"))
    }
    func testRecentCounterAndScheduledResetsDiscardOlderCycle() throws {
        let recent = try history(rollbackHour: 96)
        let rolled = recent.forecast(at: now, rule: rule(.none), intervalMinutes: 60, calendar: calendar)
        XCTAssertEqual(rolled.reason, .insufficient)
        XCTAssertEqual(rolled.eligibleDays, 2)
        let scheduled = try history().forecast(at: now, rule: rule(day: 15), intervalMinutes: 60, calendar: calendar)
        XCTAssertEqual(scheduled.reason, .insufficient)
        XCTAssertEqual(scheduled.eligibleDays, 3)
    }
    func testZeroUseUnlimitedExpiredAndPastOneTime() throws {
        let zero = try history(zero: true).forecast(at: now, rule: rule(), intervalMinutes: 60, calendar: calendar)
        XCTAssertNil(zero.estimate)
        XCTAssertEqual(zero.diagnostic, .zeroGrowth)
        XCTAssertEqual(try history(expiry: now).forecast(at: now, rule: rule(), intervalMinutes: 60, calendar: calendar).reason, .expired)
        var unlimited = Ledger()
        try unlimited.append(Subscription(upload: 0, download: 0, total: 0), at: now)
        XCTAssertEqual(unlimited.forecast(at: now, rule: rule(), intervalMinutes: 60, calendar: calendar).reason, .unlimited)
        var once = rule(.once); once.anchor = now.addingTimeInterval(-10)
        XCTAssertEqual(try history().forecast(at: now, rule: once, intervalMinutes: 60, calendar: calendar).reason, .awaitingReset)
    }

    func testExact72HoursAndFourReadingsQualifyButOneSecondShortDoesNot() throws {
        var ledger = Ledger()
        for hour in [0, 24, 48, 72] {
            try ledger.append(Subscription(upload: UInt64(hour), download: 0, total: 10000),
                              at: now.addingTimeInterval(Double(hour - 72) * 3600))
        }
        let result = ledger.forecast(at: now, rule: rule(), intervalMinutes: 5, calendar: calendar)
        XCTAssertNotNil(result.estimate)
        XCTAssertEqual(result.sampleCount, 4)
        XCTAssertEqual(result.estimate?.dailyBytes, 24)
        var short = Ledger()
        for seconds in [0, 86400, 172800, 259199] {
            try short.append(Subscription(upload: UInt64(seconds), download: 0, total: 1000000),
                             at: now.addingTimeInterval(Double(seconds - 259199)))
        }
        XCTAssertEqual(short.forecast(at: now, rule: rule(), intervalMinutes: 5, calendar: calendar).diagnostic, .insufficientHistory)
    }

    func testLongGapRestartsPredictionWithoutLosingComparableHistory() throws {
        var ledger = try history()
        let later = now.addingTimeInterval(86401)
        try ledger.append(Subscription(upload: 0, download: 15_000_000_000, total: 100_000_000_000), at: later)
        let result = ledger.forecast(at: later, rule: rule(), intervalMinutes: 5, calendar: calendar)
        XCTAssertNil(result.estimate)
        XCTAssertEqual(result.sampleCount, 1)
        XCTAssertEqual(result.observedFrom, later)
        XCTAssertEqual(ledger.observedIntervals(rule: rule()).last?.bytes, 1_800_000_000)
        XCTAssertEqual(ledger.samples.count, 134)
    }

    func testSevenDayCutoffDoesNotInterpolateAndRateUsesElapsedSeconds() throws {
        var ledger = Ledger()
        // 13-hour spacing: the first retained point is 156h ago, not an invented -168h point.
        for hour in stride(from: -195, through: 0, by: 13) {
            try ledger.append(Subscription(upload: UInt64(hour + 195) * 100, download: 0, total: 1000000),
                              at: now.addingTimeInterval(Double(hour) * 3600))
        }
        let result = ledger.forecast(at: now, rule: rule(), intervalMinutes: 5, calendar: calendar)
        XCTAssertEqual(result.observedFrom, now.addingTimeInterval(-156 * 3600))
        XCTAssertEqual(result.observedSeconds, 156 * 3600)
        XCTAssertEqual(result.estimate?.dailyBytes, 2400)
    }

    func testExplicitEligibilityStatesAndThirtyMinuteFreshnessFloor() throws {
        let ledger = try history()
        for (availability, expected) in [
            (ForecastAvailability(paused: true), ForecastDiagnostic.paused),
            (ForecastAvailability(synchronizing: true), .synchronizing),
            (ForecastAvailability(pendingVerification: true), .pendingVerification),
            (ForecastAvailability(resetRuleChanged: true), .resetRuleChanged)
        ] {
            let result = ledger.forecast(at: now, rule: rule(), intervalMinutes: 5,
                                        calendar: calendar, availability: availability)
            XCTAssertNil(result.estimate)
            XCTAssertEqual(result.diagnostic, expected)
        }
        XCTAssertNotNil(ledger.forecast(at: now.addingTimeInterval(1800), rule: rule(), intervalMinutes: 5, calendar: calendar).estimate)
        XCTAssertEqual(ledger.forecast(at: now.addingTimeInterval(1801), rule: rule(), intervalMinutes: 5, calendar: calendar).diagnostic, .staleReading)
    }

    func testExpiryEqualToResetCannotClaimEnoughUntilReset() throws {
        let expiry = date("2026-11-01T00:00:00Z")
        let result = try history(expiry: expiry).forecast(at: now, rule: rule(), intervalMinutes: 5, calendar: calendar)
        XCTAssertNil(result.estimate)
        XCTAssertEqual(result.diagnostic, .expiryBeforeReset)
    }

    func testDSTUsesActualSecondsRatherThanAssumingEveryCalendarDayHas24Hours() throws {
        var newYork = calendar; newYork.timeZone = TimeZone(identifier: "America/New_York")!
        var ledger = Ledger()
        let start = date("2026-03-06T17:00:00Z"), end = date("2026-03-09T17:00:00Z")
        // Observed points are exactly 24 elapsed hours apart across the spring change.
        for hour in [0, 24, 48, 72] {
            try ledger.append(Subscription(upload: UInt64(hour) * 10, download: 0, total: 100000),
                              at: start.addingTimeInterval(Double(hour) * 3600))
        }
        let result = ledger.forecast(at: end, rule: rule(), intervalMinutes: 5, calendar: newYork)
        XCTAssertEqual(result.observedSeconds, 72 * 3600)
        XCTAssertEqual(result.eligibleDays, 4)
        XCTAssertEqual(result.estimate?.dailyBytes, 240)
    }

    func testExpiryExtensionDoesNotBreakComparableUsage() throws {
        var ledger = try history(expiry: date("2026-11-10T00:00:00Z"))
        let later = now.addingTimeInterval(3600)
        try ledger.append(Subscription(upload: 0, download: 13_300_000_000, total: 100_000_000_000,
                                       expiry: date("2026-12-10T00:00:00Z")), at: later)
        let result = ledger.forecast(at: later, rule: rule(), intervalMinutes: 5, calendar: calendar)
        XCTAssertEqual(result.sampleCount, 134)
        XCTAssertEqual(result.estimate?.dailyBytes, 2_400_000_000)
    }

    func testFreshReadingForecastRemainsAnchoredToObservationNotViewRefreshTime() throws {
        let ledger = try history()
        let initial = ledger.forecast(at: now, rule: rule(), intervalMinutes: 5, calendar: calendar)
        let later = ledger.forecast(at: now.addingTimeInterval(20 * 60), rule: rule(), intervalMinutes: 5, calendar: calendar)
        let initialEstimate = try XCTUnwrap(initial.estimate), laterEstimate = try XCTUnwrap(later.estimate)
        XCTAssertEqual(initialEstimate.exhaustion, laterEstimate.exhaustion)
        XCTAssertEqual(initialEstimate.remainingAtBoundary, laterEstimate.remainingAtBoundary)
        XCTAssertEqual(later.observedThrough, now)
        XCTAssertEqual(later.generatedAt, now.addingTimeInterval(20 * 60))
        XCTAssertNil(ledger.forecast(at: now.addingTimeInterval(30 * 60 + 1), rule: rule(), intervalMinutes: 5, calendar: calendar).estimate)
    }

    func testRuleSavedExactlyAtSamplePreservesCompletedUsageButRestartsForecastSequence() throws {
        var ledger = try history()
        let updatedRule = rule(day: 20)
        let revisions = [StatisticsRuleRevision(effectiveAt: nil, rule: rule()),
                         StatisticsRuleRevision(effectiveAt: now, rule: updatedRule)]
        let before = ledger.observedIntervals(rule: rule()).compactMap(\.bytes).reduce(0, +)
        let atEdit = ledger.forecast(at: now, rule: updatedRule, intervalMinutes: 5,
                                     calendar: calendar, revisions: revisions)
        XCTAssertEqual(atEdit.sampleCount, 1)
        XCTAssertNil(atEdit.estimate)
        XCTAssertEqual(ledger.observedIntervals(rule: updatedRule, revisions: revisions)
            .compactMap(\.bytes).reduce(0, +), before)
        let next = now.addingTimeInterval(300)
        try ledger.append(Subscription(upload: 0, download: 13_300_000_000, total: 100_000_000_000), at: next)
        let result = ledger.forecast(at: next, rule: updatedRule, intervalMinutes: 5,
                                     calendar: calendar, revisions: revisions)
        XCTAssertEqual(result.sampleCount, 2)
        XCTAssertEqual(result.observedFrom, now)
        XCTAssertEqual(result.diagnostic, .insufficientHistory)
        XCTAssertEqual(ledger.observedIntervals(rule: updatedRule, revisions: revisions)
            .compactMap(\.bytes).reduce(0, +), before + 100_000_000)
    }
}
