import Foundation
import Testing
@testable import TrafficCore

struct SamplingForecastTests {
    let start = ISO8601DateFormatter().date(from: "2026-10-02T00:00:00Z")!
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
    }
    var rule: ResetRule {
        var value = ResetRule(); value.kind = .monthly; value.day = 1; value.timeZoneID = "UTC"; return value
    }
    func ledger(count: Int = 4, hours: Double = 72, lastGap: Double? = nil,
                rollback: Bool = false, quotaChange: Bool = false, zero: Bool = false) throws -> Ledger {
        var value = Ledger()
        for index in 0..<count {
            let time = start.addingTimeInterval((Double(index) * hours + (index == count - 1 ? lastGap ?? 0 : 0)) * 3600)
            try value.append(Subscription(upload: 0, download: rollback && index == count - 1 ? 0 : (zero ? 0 : UInt64(index) * 7_200_000_000),
                                          total: quotaChange && index == count - 1 ? 300_000_000_000 : 200_000_000_000, expiry: nil), at: time)
        }
        return value
    }
    func predict(_ value: Ledger, schedule: ResetRule? = nil, minutes: Int = 4320,
                 revisions: [StatisticsRuleRevision] = []) -> ForecastResult {
        value.forecast(at: value.samples.last!.date, rule: schedule ?? rule, intervalMinutes: minutes,
                       calendar: calendar, revisions: revisions, mode: .samplingSnapshot)
    }
    @Test func sparseSamplesWorkWithoutChangingContinuousQualification() throws {
        let value = try ledger(), latest = value.samples.last!.date
        let sampled = predict(value)
        #expect(sampled.sampleCount == 4)
        #expect(sampled.observedSeconds == 9 * 86400)
        #expect(abs(try #require(sampled.estimate).dailyBytes - 2_400_000_000) < 1)
        #expect(sampled.generatedAt == latest)
        #expect(sampled.estimate?.boundary == rule.window(at: latest).next)
        #expect(value.forecast(at: latest, rule: rule, intervalMinutes: 4320, calendar: calendar).estimate == nil)
        #expect(SubscriptionRefreshPolicy.minimumInterval == 72 * 3600)
        #expect(SubscriptionRefreshPolicy.freshnessInterval(minutes: 4320) == 1800)
    }
    @Test func fewerOrShorterSamplesAndLatestLongGapCannotBorrowOlderSequence() throws {
        #expect(predict(try ledger(count: 3)).estimate == nil)
        #expect(predict(try ledger(hours: 48)).estimate == nil)
        let result = predict(try ledger(count: 5, lastGap: 73))
        #expect(result.estimate == nil)
        #expect(result.sampleCount == 1)
    }
    @Test func weeklySamplingAndActualElapsedTime() throws {
        let value = try ledger(hours: 168)
        let result = predict(value, minutes: 10080)
        #expect(result.estimate != nil)
        #expect(result.observedSeconds == 21 * 86400)
        #expect(abs(try #require(result.estimate).dailyBytes - 7_200_000_000 / 7) < 1)
    }
    @Test func discontinuitiesResetSequence() throws {
        #expect(predict(try ledger(rollback: true)).sampleCount == 1)
        #expect(predict(try ledger(quotaChange: true)).sampleCount == 1)
        var schedule = rule; schedule.day = 8
        #expect(predict(try ledger(), schedule: schedule).estimate == nil)
        let value = try ledger(count: 5)
        let revisions = [StatisticsRuleRevision(effectiveAt: nil, rule: rule),
                         StatisticsRuleRevision(effectiveAt: start.addingTimeInterval(4 * 86400), rule: rule)]
        #expect(predict(value, revisions: revisions).estimate == nil)
        #expect(predict(try ledger(zero: true)).diagnostic == .zeroGrowth)
    }
}
