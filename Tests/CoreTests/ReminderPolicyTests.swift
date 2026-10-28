import Foundation
import Testing
@testable import TrafficCore

struct ReminderPolicyTests {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private func input(_ seconds: Double = 0, remaining: Double = 10, required: Double? = nil) -> ReminderInput {
        ReminderInput(now: origin.addingTimeInterval(seconds), sampleID: UUID(), observedAt: origin.addingTimeInterval(seconds),
                      remainingBytes: remaining * 1e9, totalBytes: 100e9, forecastRequiredBytes: required.map { $0 * 1e9 },
                      usageFresh: true, forecastEligible: required != nil, globalEnabled: true)
    }
    private func evaluate(_ input: ReminderInput, _ state: ReminderState = ReminderState(),
                          _ preferences: ReminderPreferences = ReminderPreferences()) -> ReminderDecision {
        ReminderPolicy.evaluate(input: input, preferences: preferences, state: state)
    }
    private func accept(_ decision: ReminderDecision, at seconds: Double = 0) -> ReminderState {
        ReminderPolicy.markAccepted(decision.reasons, at: origin.addingTimeInterval(seconds), state: decision.state)
    }
    private func kinds(_ decision: ReminderDecision) -> [ReminderReason.Kind] { decision.reasons.map(\.kind) }

    @Test func storedReminderPreferencesKeepTheirEnabledAndDisabledBoundaries() {
        let thresholds: [(ReminderPreferences.ThresholdMode, Double, Bool)] = [
            (.percent, 0, false), (.percent, 0.999, false), (.percent, 1, true),
            (.percent, 50, true), (.percent, 50.001, false),
            (.legacyAbsoluteGB, 0, false), (.legacyAbsoluteGB, 0.001, true),
            (.legacyAbsoluteGB, 1_000_000, true), (.legacyAbsoluteGB, 1_000_001, false),
            (.percent, .nan, false), (.percent, .infinity, false),
            (.legacyAbsoluteGB, -.infinity, false)
        ]
        for (mode, value, validWhenEnabled) in thresholds {
            var preferences = ReminderPreferences(lowThreshold: value, thresholdMode: mode)
            #expect(preferences.isValid == validWhenEnabled)
            preferences.lowEnabled = false
            #expect(preferences.isValid == value.isFinite)
        }

        for (days, validWhenEnabled) in [(1, false), (2, true), (30, true), (31, false)] {
            var preferences = ReminderPreferences(expiryLeadDays: days)
            #expect(preferences.isValid == validWhenEnabled)
            preferences.expiryEnabled = false
            #expect(preferences.isValid)
        }
    }

    @Test func allScopeAndTypeCombinations() {
        for scope in 0..<16 {
            for types in 0..<8 {
                var i = input(remaining: 10, required: 20)
                i.expiry = origin.addingTimeInterval(3600)
                i.globalEnabled = scope & 1 != 0; i.airportEnabled = scope & 2 != 0
                i.paused = scope & 4 != 0; i.archived = scope & 8 != 0
                let p = ReminderPreferences(lowEnabled: types & 1 != 0, forecastEnabled: types & 2 != 0, expiryEnabled: types & 4 != 0)
                let first = evaluate(i, ReminderState(), p)
                i.now.addTimeInterval(300); i.observedAt = i.now; i.sampleID = UUID()
                let result = evaluate(i, first.state, p)
                if scope == 3 {
                    #expect(kinds(result).contains(.low) == p.lowEnabled)
                    #expect(kinds(result).contains(.forecast) == p.forecastEnabled)
                    #expect(kinds(result).contains(.expiryDay) == p.expiryEnabled)
                } else { #expect(result.reasons.isEmpty) }
            }
        }
    }

    @Test func lowThresholdUsesUnroundedValuesAndExhaustionSubsumesLow() {
        #expect(kinds(evaluate(input(remaining: 10))) == [.low])
        #expect(evaluate(input(remaining: 10.0000001)).reasons.isEmpty)
        let low = accept(evaluate(input()))
        #expect(evaluate(input(300, remaining: 9), low).reasons.isEmpty)
        #expect(kinds(evaluate(input(600, remaining: 0), low)) == [.exhausted])
        let direct = accept(evaluate(input(remaining: 0)))
        #expect(direct.lowNotified && direct.exhaustedNotified)
        #expect(evaluate(input(300, remaining: 1), direct).reasons.isEmpty)
    }

    @Test func unknownAndMalformedAmountsAreNotZero() {
        for invalid in [Double.nan, .infinity, -1] {
            var i = input(remaining: 0); i.remainingBytes = invalid
            #expect(evaluate(i).reasons.isEmpty)
        }
        var i = input(remaining: 0); i.totalBytes = nil
        #expect(evaluate(i).reasons.isEmpty)
        i.totalBytes = 0
        #expect(evaluate(i).reasons.isEmpty)
        i.totalBytes = 100e9; i.remainingBytes = nil
        #expect(evaluate(i).reasons.isEmpty)
        i = input(); i.usageFresh = false
        #expect(evaluate(i).reasons.isEmpty)
    }

    @Test func lowRecoveryNeedsTwoNewSamplesAboveStrictRecoveryLine() {
        var s = accept(evaluate(input()))
        s = evaluate(input(300, remaining: 12), s).state
        s = evaluate(input(600, remaining: 13), s).state
        #expect(s.lowNotified)
        let same = input(600, remaining: 13)
        var later = same; later.now.addTimeInterval(300)
        s = evaluate(later, s).state
        #expect(s.lowNotified)
        s = evaluate(input(900, remaining: 13), s).state
        #expect(!s.lowNotified)
        #expect(evaluate(input(1000, remaining: 9), s).reasons.isEmpty)
        var stale = input(1000, remaining: 9); stale.now = origin.addingTimeInterval(86_400)
        #expect(evaluate(stale, s).reasons.isEmpty)
        #expect(kinds(evaluate(input(86_400, remaining: 9), s)) == [.low])
    }

    @Test func changingThresholdCannotManufactureRecoveryConfirmation() {
        var s = accept(evaluate(input()))
        let i = input(300, remaining: 20)
        s = evaluate(i, s).state
        let p = ReminderPreferences(lowThreshold: 5)
        var later = i; later.now.addTimeInterval(300)
        s = evaluate(later, s, p).state
        #expect(s.lowNotified)
        s = evaluate(input(600, remaining: 20), s, p).state
        #expect(s.lowNotified)
        s = evaluate(input(900, remaining: 20), s, p).state
        #expect(!s.lowNotified)
    }

    @Test func exhaustionRequiresTwoPositiveSamplesToRearm() {
        var s = accept(evaluate(input(remaining: 0)))
        s = evaluate(input(300, remaining: 0.001), s).state
        #expect(evaluate(input(600, remaining: 0), s).reasons.isEmpty)
        s = evaluate(input(600, remaining: 0), s).state
        s = evaluate(input(900, remaining: 1), s).state
        s = evaluate(input(1200, remaining: 1), s).state
        #expect(kinds(evaluate(input(1201, remaining: 0), s)) == [.exhausted])
    }

    @Test func forecastNeedsTwoSuccessesFiveMinutesApart() {
        let p = ReminderPreferences(lowEnabled: false)
        let first = input(remaining: 20, required: 22)
        var s = evaluate(first, ReminderState(), p).state
        var repeated = first; repeated.now.addTimeInterval(600)
        #expect(evaluate(repeated, s, p).reasons.isEmpty)
        let short = evaluate(input(299, remaining: 20, required: 22), s, p)
        #expect(short.reasons.isEmpty); s = short.state
        let second = evaluate(input(300, remaining: 20, required: 22), s, p)
        #expect(kinds(second) == [.forecast])
        let accepted = accept(second, at: 300)
        #expect(evaluate(input(100_000, remaining: 20, required: 22), accepted, p).reasons.isEmpty)
    }

    @Test func failureOrIneligibleDataBreaksPendingButNotDeliveredRisk() {
        let p = ReminderPreferences(lowEnabled: false)
        for unavailable in 0..<4 {
            var s = evaluate(input(remaining: 20, required: 22), ReminderState(), p).state
            var bad = input(300, remaining: 20, required: 22)
            switch unavailable {
            case 0: bad.usageFresh = false
            case 1: bad.forecastEligible = false
            case 2: bad.forecastRequiredBytes = nil
            default: bad.forecastRequiredBytes = 21e9
            }
            s = evaluate(bad, s, p).state
            let first = evaluate(input(600, remaining: 20, required: 22), s, p)
            #expect(first.reasons.isEmpty)
            let second = evaluate(input(900, remaining: 20, required: 22), first.state, p)
            #expect(kinds(second) == [.forecast])
            s = accept(second, at: 900)
            s = evaluate(bad, s, p).state
            #expect(s.forecastNotified)
        }
    }

    @Test func forecastRecoveryAndCooldownRequireFreshDoubleConfirmation() {
        let p = ReminderPreferences(lowEnabled: false)
        var s = evaluate(input(remaining: 20, required: 22), ReminderState(), p).state
        s = accept(evaluate(input(300, remaining: 20, required: 22), s, p), at: 300)
        s = evaluate(input(600, remaining: 20, required: 18), s, p).state
        s = evaluate(input(900, remaining: 20, required: 18), s, p).state
        #expect(!s.forecastNotified)
        s = evaluate(input(86_699, remaining: 20, required: 22), s, p).state
        #expect(s.forecastTrigger == nil)
        let first = evaluate(input(86_700, remaining: 20, required: 22), s, p)
        #expect(first.reasons.isEmpty)
        #expect(kinds(evaluate(input(87_000, remaining: 20, required: 22), first.state, p)) == [.forecast])
    }

    @Test func expiryHighestCurrentStageAndExactBoundaries() {
        for (seconds, expected) in [(7.0 * 86400, ReminderReason.Kind.expirySoon), (86400, .expiryDay), (0, .expired), (-1, .expired)] {
            var i = input(remaining: 90); i.expiry = origin.addingTimeInterval(seconds)
            #expect(kinds(evaluate(i)) == [expected])
        }
        var i = input(remaining: 90); i.expiry = origin.addingTimeInterval(7 * 86400 + 1)
        #expect(evaluate(i).reasons.isEmpty)
        #expect(kinds(evaluate(i, ReminderState(), ReminderPreferences(expiryLeadDays: 8))) == [.expirySoon])
    }

    @Test func expiryEscalatesWithoutReplayingAndMissingDateDoesNotReset() {
        var i = input(remaining: 90); i.expiry = origin.addingTimeInterval(86401)
        var s = accept(evaluate(i))
        var missing = i; missing.expiry = nil
        s = evaluate(missing, s).state
        #expect(evaluate(i, s).reasons.isEmpty)
        i.now.addTimeInterval(1)
        let day = evaluate(i, s)
        #expect(kinds(day) == [.expiryDay]); s = accept(day, at: 1)
        i.now = i.expiry!
        let expired = evaluate(i, s)
        #expect(kinds(expired) == [.expired]); s = accept(expired, at: 86401)
        i.now = origin
        #expect(evaluate(i, s).reasons.isEmpty)
    }

    @Test func expiryCorrectionSameStageWaitsButUpgradeCanProceed() {
        var i = input(remaining: 90); i.expiry = origin.addingTimeInterval(3 * 86400)
        var s = accept(evaluate(i))
        i.expiry!.addTimeInterval(60); i.now.addTimeInterval(60)
        #expect(evaluate(i, s).reasons.isEmpty)
        i.now.addTimeInterval(86400)
        let corrected = evaluate(i, s)
        #expect(kinds(corrected) == [.expirySoon]); s = accept(corrected, at: 86460)
        i.now = i.expiry!.addingTimeInterval(-86400)
        #expect(kinds(evaluate(i, s)) == [.expiryDay])
    }

    @Test func staleExpiryIsExplicitlyUnverifiedAndPauseSuppressesIt() {
        var i = input(); i.usageFresh = false; i.expiry = origin.addingTimeInterval(3600)
        let d = evaluate(i)
        #expect(kinds(d) == [.expiryDay]); #expect(d.reasons.first?.expiryUnverified == true)
        i.paused = true
        #expect(evaluate(i).reasons.isEmpty)
    }

    @Test func acceptedStateRoundTripsAndSameSourceKeepsEvents() throws {
        var i = input(remaining: 0); i.expiry = origin
        let d = evaluate(i)
        #expect(kinds(d) == [.exhausted, .expired])
        let s = accept(d)
        let decoded = try JSONDecoder().decode(ReminderState.self, from: JSONEncoder().encode(s))
        #expect(decoded == s)
        #expect(evaluate(i, decoded).reasons.isEmpty)
        #expect(kinds(evaluate(i, ReminderState())) == [.exhausted, .expired])
    }

    @Test func rejectionDoesNotMarkRiskDelivered() {
        let i = input()
        let candidate = evaluate(i)
        #expect(!candidate.state.lowNotified)
        #expect(kinds(evaluate(i, candidate.state)) == [.low])
        #expect(evaluate(i, accept(candidate)).reasons.isEmpty)
    }

    @Test func legacyThresholdPreservesGBAndRequiresKnownTotalForRecovery() {
        let p = ReminderPreferences(lowThreshold: 5, thresholdMode: .legacyAbsoluteGB)
        var i = input(remaining: 5); i.totalBytes = nil
        var s = accept(evaluate(i, ReminderState(), p))
        #expect(s.lowNotified)
        i = input(300, remaining: 20); i.totalBytes = nil
        s = evaluate(i, s, p).state
        i = input(600, remaining: 20); i.totalBytes = nil
        s = evaluate(i, s, p).state
        #expect(s.lowNotified)
        s = evaluate(input(900, remaining: 7), s, p).state
        s = evaluate(input(1200, remaining: 8), s, p).state
        #expect(s.lowNotified)
        s = evaluate(input(1500, remaining: 8), s, p).state
        #expect(!s.lowNotified)
    }

    @Test func pausedConfirmationCannotCountAcrossPauseAndReenable() {
        let p = ReminderPreferences(lowEnabled: false)
        var s = evaluate(input(remaining: 20, required: 22), ReminderState(), p).state
        var i = input(300, remaining: 20, required: 22); i.paused = true
        s = evaluate(i, s, p).state
        let first = evaluate(input(600, remaining: 20, required: 22), s, p)
        #expect(first.reasons.isEmpty)
        #expect(kinds(evaluate(input(900, remaining: 20, required: 22), first.state, p)) == [.forecast])
    }

    @Test func onlyExplicitConfirmedBoundariesResetEventsAndRetainCooldown() {
        var s = accept(evaluate(input(remaining: 0)))
        var i = input(300, remaining: 0)
        #expect(evaluate(i, s).reasons.isEmpty)
        i.confirmedCycleID = UUID()
        let nextCycle = evaluate(i, s)
        #expect(kinds(nextCycle) == [.exhausted]); s = accept(nextCycle, at: 300)
        i = input(600, remaining: 0)
        i.confirmedCycleID = s.confirmedCycleID
        #expect(evaluate(i, s).reasons.isEmpty)
    }

    @Test func outOfOrderAndReplayedSamplesCannotConfirmForecast() {
        let p = ReminderPreferences(lowEnabled: false)
        let first = input(600, remaining: 20, required: 22)
        var s = evaluate(first, ReminderState(), p).state
        var old = input(0, remaining: 20, required: 22); old.now = origin.addingTimeInterval(900)
        s = evaluate(old, s, p).state
        #expect(s.lastSampleID == first.sampleID)
        var replay = first; replay.now = origin.addingTimeInterval(1200)
        #expect(evaluate(replay, s, p).reasons.isEmpty)
        #expect(kinds(evaluate(input(900, remaining: 20, required: 22), s, p)) == [.forecast])
    }

    @Test func allKindsMergeInPriorityOrderAndSelectionChangesPreserveDedup() {
        var first = input(remaining: 10, required: 12)
        first.expiry = origin.addingTimeInterval(100)
        var s = evaluate(first).state
        var second = input(300, remaining: 10, required: 12); second.expiry = first.expiry
        let merged = evaluate(second, s)
        #expect(kinds(merged) == [.expired, .low, .forecast])
        s = accept(merged, at: 300)
        s = evaluate(second, s, ReminderPreferences(lowEnabled: false, forecastEnabled: false, expiryEnabled: false)).state
        #expect(s.lowNotified && s.forecastNotified)
        #expect(evaluate(second, s).reasons.isEmpty)
    }

    @Test func explicitSequenceChangeRearmsOnlyPredictionAndDoesNotSkipCooldown() {
        var s = evaluate(input(remaining: 10, required: 12)).state
        s = accept(evaluate(input(300, remaining: 10, required: 12), s), at: 300)
        var i = input(600, remaining: 10, required: 12); i.confirmedSequenceID = UUID()
        s = evaluate(i, s).state
        #expect(s.lowNotified && !s.forecastNotified)
        #expect(s.forecastLastAcceptedAt == origin.addingTimeInterval(300))
        #expect(s.forecastTrigger == nil)
    }

    @Test func exhaustionAlsoStartsLowCooldownAndZeroLegacyThresholdIsInvalid() {
        var s = accept(evaluate(input(remaining: 0)))
        s = evaluate(input(300, remaining: 20), s).state
        s = evaluate(input(600, remaining: 20), s).state
        #expect(evaluate(input(900, remaining: 5), s).reasons.isEmpty)
        let p = ReminderPreferences(lowThreshold: 0, thresholdMode: .legacyAbsoluteGB)
        var i = input(remaining: 0); i.totalBytes = nil
        #expect(evaluate(i, ReminderState(), p).reasons.isEmpty)
    }

    @Test func genuineExpiryUpgradeAfterRenewalBypassesOldSameStageCooldown() {
        var i = input(remaining: 90); i.expiry = origin.addingTimeInterval(3600)
        var s = accept(evaluate(i))
        i.now.addTimeInterval(60); i.expiry = origin.addingTimeInterval(3 * 86400)
        let renewal = evaluate(i, s)
        #expect(kinds(renewal) == [.expirySoon]); s = accept(renewal, at: 60)
        i.now.addTimeInterval(60); i.expiry = origin.addingTimeInterval(7200)
        #expect(kinds(evaluate(i, s)) == [.expiryDay])
    }

    @Test func interruptionCannotReuseOriginalSampleAsFirstNewConfirmation() {
        let p = ReminderPreferences(lowEnabled: false)
        for mode in 0..<3 {
            let original = input(remaining: 20, required: 22)
            var s = evaluate(original, ReminderState(), p).state
            var interrupted = original
            if mode == 0 { interrupted.usageFresh = false }
            if mode == 1 { interrupted.globalEnabled = false }
            if mode == 2 { interrupted.forecastEligible = false }
            s = evaluate(interrupted, s, p).state
            s = evaluate(original, s, p).state
            #expect(s.forecastTrigger == nil)
            let first = evaluate(input(300, remaining: 20, required: 22), s, p)
            #expect(first.reasons.isEmpty)
            #expect(kinds(evaluate(input(600, remaining: 20, required: 22), first.state, p)) == [.forecast])
        }
    }
}
