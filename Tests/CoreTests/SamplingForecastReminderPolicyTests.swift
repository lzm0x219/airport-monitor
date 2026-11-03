import Foundation
import Testing
@testable import TrafficCore

struct SamplingForecastReminderPolicyTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func thresholdAndRepeatedObservation() {
        let id = UUID()
        let result = SamplingForecastReminderPolicy.evaluate(state: .init(), sampleID: id, observedAt: start,
            now: start, remaining: 100, required: 110, eligible: true)
        #expect(result.shouldNotify)
        let repeated = SamplingForecastReminderPolicy.evaluate(state: result.state, sampleID: id, observedAt: start,
            now: start.addingTimeInterval(100), remaining: 100, required: 110, eligible: true)
        #expect(!repeated.shouldNotify)
        let below = SamplingForecastReminderPolicy.evaluate(state: .init(), sampleID: UUID(), observedAt: start,
            now: start, remaining: 100, required: 109, eligible: true)
        #expect(!below.shouldNotify)
    }

    @Test func recoveryRequiresTwoValidNewObservations() {
        var state = SamplingForecastReminderPolicy.State(notified: true)
        func step(_ day: Double, _ required: Double?, eligible: Bool = true) -> SamplingForecastReminderPolicy.Result {
            let date = start.addingTimeInterval(day * 86400)
            return SamplingForecastReminderPolicy.evaluate(state: state, sampleID: UUID(), observedAt: date,
                now: date, remaining: 100, required: required, eligible: eligible)
        }
        state = step(1, 90).state
        #expect(state.notified && state.recoverySampleID != nil)
        state = step(2, nil, eligible: false).state
        #expect(state.notified && state.recoverySampleID == nil)
        state = step(3, 90).state
        state = step(4, 90).state
        #expect(!state.notified)
        #expect(step(5, 110).shouldNotify)
    }

    @Test func unknownAndInvalidAmountsCannotTrigger() {
        for remaining in [0.0, -1, .nan, .infinity] {
            let result = SamplingForecastReminderPolicy.evaluate(state: .init(), sampleID: UUID(), observedAt: start,
                now: start, remaining: remaining, required: 200, eligible: true)
            #expect(!result.shouldNotify)
        }
    }
    @Test func scheduledResetAndLateAcceptanceStayWithinTheirRisk() {
        var state = SamplingForecastReminderPolicy.State(notified: true)
        state.trackingSince = start
        let oldRisk = state.riskID
        let boundary = start.addingTimeInterval(86400)
        let observed = start.addingTimeInterval(10 * 86400)
        let unavailable = SamplingForecastReminderPolicy.evaluate(state: state, sampleID: UUID(), observedAt: observed,
            now: observed, remaining: 100, required: nil, eligible: false, scheduledBoundary: boundary)
        #expect(unavailable.state.notified)
        let next = SamplingForecastReminderPolicy.evaluate(state: unavailable.state, sampleID: UUID(), observedAt: observed.addingTimeInterval(1),
            now: observed.addingTimeInterval(1), remaining: 100, required: 110, eligible: true, scheduledBoundary: boundary)
        #expect(next.shouldNotify)
        #expect(next.state.riskID != oldRisk)
        let late = SamplingForecastReminderPolicy.markAccepted(state: next.state, riskID: oldRisk, at: observed)
        #expect(!late.notified)
        #expect(SamplingForecastReminderPolicy.markAccepted(state: late, riskID: late.riskID, at: observed).notified)
    }

    @Test func ruleChangeDoesNotTreatPreviousBoundaryAsNewCycle() {
        let changedAt = start.addingTimeInterval(5 * 86400)
        let state = SamplingForecastReminderPolicy.ruleChanged(state: .init(notified: true), at: changedAt)
        let observed = start.addingTimeInterval(15 * 86400)
        let result = SamplingForecastReminderPolicy.evaluate(state: state, sampleID: UUID(), observedAt: observed,
            now: observed, remaining: 100, required: 120, eligible: true,
            scheduledBoundary: start.addingTimeInterval(3 * 86400))
        #expect(result.state.notified)
        #expect(!result.shouldNotify)
    }

    @Test func cooldownRequiresNewObservationAfterDeadline() {
        var state = SamplingForecastReminderPolicy.State()
        state.lastAcceptedAt = start
        let early = start.addingTimeInterval(86399)
        let first = SamplingForecastReminderPolicy.evaluate(state: state, sampleID: UUID(), observedAt: early,
            now: early, remaining: 100, required: 110, eligible: true)
        #expect(!first.shouldNotify)
        let deadline = start.addingTimeInterval(86400)
        let result = SamplingForecastReminderPolicy.evaluate(state: first.state, sampleID: UUID(), observedAt: deadline,
            now: deadline, remaining: 100, required: 110, eligible: true)
        #expect(result.shouldNotify)
    }
    @Test func persistedCandidateCanBeRecheckedButNotRecreatedAfterCancellation() throws {
        let id = UUID()
        let first = SamplingForecastReminderPolicy.evaluate(state: .init(), sampleID: id, observedAt: start,
            now: start, remaining: 100, required: 110, eligible: true)
        let saved = try JSONDecoder().decode(SamplingForecastReminderPolicy.State.self,
            from: JSONEncoder().encode(first.state))
        let retry = SamplingForecastReminderPolicy.evaluate(state: saved, sampleID: id, observedAt: start,
            now: start, remaining: 100, required: 110, eligible: true, resumePending: true)
        #expect(retry.shouldNotify)
        let cancelled = SamplingForecastReminderPolicy.cancelPending(state: retry.state)
        let reopened = SamplingForecastReminderPolicy.evaluate(state: cancelled, sampleID: id, observedAt: start,
            now: start, remaining: 100, required: 110, eligible: true, resumePending: true)
        #expect(!reopened.shouldNotify)
    }

    @Test func invalidationCancelsPendingWithoutMarkingItAccepted() {
        let id = UUID()
        let first = SamplingForecastReminderPolicy.evaluate(state: .init(), sampleID: id, observedAt: start,
            now: start, remaining: 100, required: 110, eligible: true)
        let invalid = SamplingForecastReminderPolicy.evaluate(state: first.state, sampleID: id, observedAt: start,
            now: start, remaining: 100, required: nil, eligible: false, resumePending: true)
        #expect(invalid.state.pendingSampleID == nil)
        #expect(!invalid.state.notified)
    }
    @Test func migrationPreservesDeduplicationAndDoesNotReplayOldReading() {
        let id = UUID()
        let migrationAt = start.addingTimeInterval(86400)
        let state = SamplingForecastReminderPolicy.migrate(notified: true, lastAcceptedAt: start,
            latestSampleID: id, latestObservedAt: start, at: migrationAt)
        let old = SamplingForecastReminderPolicy.evaluate(state: state, sampleID: id, observedAt: start,
            now: migrationAt, remaining: 100, required: 110, eligible: true)
        #expect(old.state.notified)
        #expect(!old.shouldNotify)
    }

    @Test func pendingOldCycleIsNotRetriedAfterReset() {
        let id = UUID()
        let first = SamplingForecastReminderPolicy.evaluate(state: .init(), sampleID: id, observedAt: start,
            now: start, remaining: 100, required: 110, eligible: true)
        let reset = start.addingTimeInterval(3600)
        let retry = SamplingForecastReminderPolicy.evaluate(state: first.state, sampleID: id, observedAt: start,
            now: reset, remaining: 100, required: 110, eligible: true, scheduledBoundary: reset, resumePending: true)
        #expect(!retry.shouldNotify)
        #expect(retry.state.pendingSampleID == nil)
    }
    @Test func disabledReminderRecordsWatermarkBeforeSamplingStateExists() {
        let id = UUID()
        var input = ReminderInput(now: start, sampleID: id, observedAt: start, remainingBytes: 100,
            totalBytes: 1000, forecastRequiredBytes: 110, usageFresh: true, forecastEligible: true,
            globalEnabled: false)
        input.samplingForecast = SamplingForecastContext(scheduledBoundary: nil, ruleID: UUID(), ruleEffectiveAt: nil)
        let disabled = ReminderPolicy.evaluate(input: input, preferences: .init(lowEnabled: false), state: .init())
        input.globalEnabled = true
        let reopened = ReminderPolicy.evaluate(input: input, preferences: .init(lowEnabled: false), state: disabled.state)
        #expect(reopened.reasons.isEmpty)
        input.now.addTimeInterval(72 * 3600); input.observedAt = input.now; input.sampleID = UUID()
        let next = ReminderPolicy.evaluate(input: input, preferences: .init(lowEnabled: false), state: reopened.state)
        #expect(next.reasons.map(\.kind) == [.forecast])
    }

    @Test func legacyPendingAcceptanceReservesMigratedRisk() {
        var state = ReminderState()
        state.samplingForecastState = SamplingForecastReminderPolicy.migrate(notified: false, lastAcceptedAt: nil,
            latestSampleID: UUID(), latestObservedAt: start, at: start)
        let result = ReminderPolicy.markAccepted([ReminderReason(kind: .forecast)], at: start, state: state)
        #expect(result.samplingForecastState?.notified == true)
        #expect(result.samplingForecastState?.lastAcceptedAt == start)
    }
}
