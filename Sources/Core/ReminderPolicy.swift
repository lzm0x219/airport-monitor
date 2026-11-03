import Foundation

public struct ReminderPreferences: Codable, Equatable, Sendable {
    public enum ThresholdMode: String, Codable, Sendable { case percent, legacyAbsoluteGB }
    public var lowEnabled: Bool
    public var forecastEnabled: Bool
    public var expiryEnabled: Bool
    public var lowThreshold: Double
    public var thresholdMode: ThresholdMode
    public var expiryLeadDays: Int

    /// Valid values for an enabled low-balance reminder, shared by storage and editing.
    public static func isValidLowThreshold(_ value: Double, mode: ThresholdMode) -> Bool {
        guard value.isFinite else { return false }
        switch mode {
        case .percent: return (1...50).contains(value)
        case .legacyAbsoluteGB: return value > 0 && value <= 1_000_000
        }
    }

    /// Valid values for an enabled expiry reminder.
    public static func isValidExpiryLeadDays(_ value: Int) -> Bool {
        (2...30).contains(value)
    }

    public var isValid: Bool {
        guard lowThreshold.isFinite else { return false }
        if lowEnabled && !Self.isValidLowThreshold(lowThreshold, mode: thresholdMode) { return false }
        return !expiryEnabled || Self.isValidExpiryLeadDays(expiryLeadDays)
    }

    public init(lowEnabled: Bool = true, forecastEnabled: Bool = true, expiryEnabled: Bool = true,
                lowThreshold: Double = 10, thresholdMode: ThresholdMode = .percent, expiryLeadDays: Int = 7) {
        self.lowEnabled = lowEnabled; self.forecastEnabled = forecastEnabled; self.expiryEnabled = expiryEnabled
        self.lowThreshold = lowThreshold; self.thresholdMode = thresholdMode; self.expiryLeadDays = expiryLeadDays
    }
}

public struct ReminderInput: Sendable {
    public var now: Date
    public var sampleID: UUID?
    public var observedAt: Date?
    public var remainingBytes: Double?
    public var totalBytes: Double?
    public var expiry: Date?
    public var forecastRequiredBytes: Double?
    public var usageFresh: Bool
    public var forecastEligible: Bool
    public var globalEnabled: Bool
    public var airportEnabled: Bool
    public var paused: Bool
    public var archived: Bool
    /// Only explicit confirmed boundaries belong here; an estimated reset or counter rollback is insufficient.
    public var confirmedCycleID: UUID?
    public var confirmedSequenceID: UUID?
    /// Nil preserves legacy continuous-forecast behavior for legacy callers.
    public var samplingForecast: SamplingForecastContext?
    public var resumeSamplingCandidate = false

    public init(now: Date, sampleID: UUID? = nil, observedAt: Date? = nil, remainingBytes: Double? = nil,
                totalBytes: Double? = nil, expiry: Date? = nil, forecastRequiredBytes: Double? = nil,
                usageFresh: Bool = false, forecastEligible: Bool = false, globalEnabled: Bool = false,
                airportEnabled: Bool = true, paused: Bool = false, archived: Bool = false,
                confirmedCycleID: UUID? = nil, confirmedSequenceID: UUID? = nil) {
        self.now = now; self.sampleID = sampleID; self.observedAt = observedAt
        self.remainingBytes = remainingBytes; self.totalBytes = totalBytes; self.expiry = expiry
        self.forecastRequiredBytes = forecastRequiredBytes; self.usageFresh = usageFresh
        self.forecastEligible = forecastEligible; self.globalEnabled = globalEnabled
        self.airportEnabled = airportEnabled; self.paused = paused; self.archived = archived
        self.confirmedCycleID = confirmedCycleID; self.confirmedSequenceID = confirmedSequenceID
    }
}

public struct SamplingForecastContext: Sendable {
    public var scheduledBoundary: Date?
    public var ruleID: UUID?
    public var ruleEffectiveAt: Date?
    public var priorSampleID: UUID?
    public var priorObservedAt: Date?
    public init(scheduledBoundary: Date?, ruleID: UUID?, ruleEffectiveAt: Date?,
                priorSampleID: UUID? = nil, priorObservedAt: Date? = nil) {
        self.scheduledBoundary = scheduledBoundary
        self.ruleID = ruleID
        self.ruleEffectiveAt = ruleEffectiveAt
        self.priorSampleID = priorSampleID
        self.priorObservedAt = priorObservedAt
    }
}

public struct ReminderReason: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case exhausted, expired, expiryDay, low, forecast, expirySoon
    }
    public var kind: Kind
    public var expiry: Date?
    public var expiryUnverified: Bool
    public var forecastRiskID: UUID?
    public init(kind: Kind, expiry: Date? = nil, expiryUnverified: Bool = false, forecastRiskID: UUID? = nil) {
        self.kind = kind; self.expiry = expiry; self.expiryUnverified = expiryUnverified
        self.forecastRiskID = forecastRiskID
    }
}

public struct ReminderConfirmation: Codable, Equatable, Sendable {
    public var firstSampleID: UUID
    public var firstObservedAt: Date
    public var confirmed: Bool = false
    fileprivate var criterion: String
}

public struct ReminderExpiryRecord: Codable, Equatable, Sendable {
    public var expiry: Date
    public var highestStage: Int
}

/// Stored per stable source identity. Editing a credential or a setting must not replace this value.
public struct ReminderState: Codable, Equatable, Sendable {
    public var lowNotified = false
    public var exhaustedNotified = false
    public var forecastNotified = false
    public var lowLastAcceptedAt: Date?
    public var forecastLastAcceptedAt: Date?
    public var expiryLastAcceptedAt: [String: Date] = [:]
    public var expiryRecords: [ReminderExpiryRecord] = []
    public var latestExpiryStage: Int?
    public var lowRecovery: ReminderConfirmation?
    public var exhaustionRecovery: ReminderConfirmation?
    public var forecastTrigger: ReminderConfirmation?
    public var forecastRecovery: ReminderConfirmation?
    public var lastSampleID: UUID?
    public var lastObservedAt: Date?
    public var confirmedCycleID: UUID?
    public var confirmedSequenceID: UUID?
    public var samplingForecastState: SamplingForecastReminderPolicy.State?
    public init() {}
}

public struct ReminderDecision: Sendable {
    public var state: ReminderState
    public var reasons: [ReminderReason]
}

/// Pure decision logic. Permission, durable request intents and failed-delivery retry timing belong to the caller.
public enum ReminderPolicy {
    public static let confirmationInterval: TimeInterval = 300
    public static let cooldown: TimeInterval = 86_400

    public static func evaluate(input: ReminderInput, preferences p: ReminderPreferences,
                                state original: ReminderState) -> ReminderDecision {
        var state = original
        var reasons: [ReminderReason] = []
        guard input.globalEnabled, input.airportEnabled, !input.paused, !input.archived else {
            clearConfirmations(&state)
            if let context = input.samplingForecast {
                var sampling = state.samplingForecastState ?? SamplingForecastReminderPolicy.migrate(
                    notified: state.forecastNotified, lastAcceptedAt: state.forecastLastAcceptedAt,
                    latestSampleID: input.sampleID, latestObservedAt: input.observedAt, at: input.now)
                if sampling.ruleID == nil { sampling.ruleID = context.ruleID }
                sampling.pendingSampleID = nil
                sampling.pendingAuthorized = nil
                if let id = input.sampleID, let observed = input.observedAt, observed <= input.now,
                   sampling.lastObservedAt.map({ observed > $0 }) ?? true {
                    sampling.lastSampleID = id; sampling.lastObservedAt = observed
                }
                state.samplingForecastState = sampling
            }
            return ReminderDecision(state: state, reasons: [])
        }
        // Only a newly saved successful observation advances a confirmation. Re-evaluation, wake and
        // settings changes cannot manufacture the second observation, even if five minutes elapsed.
        let validSample = input.usageFresh && input.sampleID != nil && input.observedAt != nil
            && input.observedAt! <= input.now
        let newSample = validSample && input.sampleID != state.lastSampleID
            && (state.lastObservedAt == nil || input.observedAt! > state.lastObservedAt!)
        if newSample {
            state.lastSampleID = input.sampleID; state.lastObservedAt = input.observedAt
            if let cycle = input.confirmedCycleID, cycle != state.confirmedCycleID {
                state.confirmedCycleID = cycle
                state.lowNotified = false; state.exhaustedNotified = false; state.forecastNotified = false
                clearConfirmations(&state)
            }
            if let sequence = input.confirmedSequenceID, sequence != state.confirmedSequenceID {
                state.confirmedSequenceID = sequence; state.forecastNotified = false
                state.forecastTrigger = nil; state.forecastRecovery = nil
            }
        }
        let remaining = finiteNonnegative(input.remainingBytes)
        let total = finitePositive(input.totalBytes)
        let usageValid = validSample && remaining != nil
        if p.lowEnabled, usageValid, let remaining {
            let threshold: Double?
            switch p.thresholdMode {
            case .percent:
                threshold = (1...50).contains(p.lowThreshold) ? total.map { $0 * p.lowThreshold / 100 } : nil
            case .legacyAbsoluteGB:
                threshold = p.lowThreshold.isFinite && p.lowThreshold > 0 ? p.lowThreshold * 1e9 : nil
            }
            let recovery = threshold.flatMap { threshold in total.map { min($0, threshold + $0 * 0.02) } }
            let criterion = "\(p.thresholdMode.rawValue):\(p.lowThreshold):\(total ?? -1)"
            advance(&state.lowRecovery, condition: recovery.map { remaining > $0 } ?? false,
                    criterion: criterion, input: input, isNew: newSample)
            if state.lowRecovery?.confirmed == true {
                state.lowNotified = false; state.lowRecovery = nil
            }
            advance(&state.exhaustionRecovery, condition: remaining > 0, criterion: "positive",
                    input: input, isNew: newSample)
            if state.exhaustionRecovery?.confirmed == true {
                state.exhaustedNotified = false; state.exhaustionRecovery = nil
            }
            if remaining == 0, total != nil {
                if !state.exhaustedNotified { reasons.append(ReminderReason(kind: .exhausted)) }
            } else if let threshold, remaining <= threshold, !state.lowNotified,
                      cooldownPassed(state.lowLastAcceptedAt, at: input.now),
                      freshAfterCooldown(state.lowLastAcceptedAt, observedAt: input.observedAt) {
                reasons.append(ReminderReason(kind: .low))
            }
        } else {
            state.lowRecovery = nil; state.exhaustionRecovery = nil
        }

        if let context = input.samplingForecast,
           state.samplingForecastState != nil || (p.forecastEnabled && usageValid && input.forecastEligible) {
            var sampling = state.samplingForecastState ?? SamplingForecastReminderPolicy.migrate(
                notified: state.forecastNotified, lastAcceptedAt: state.forecastLastAcceptedAt,
                latestSampleID: original.lastSampleID ?? context.priorSampleID ?? input.sampleID,
                latestObservedAt: original.lastObservedAt ?? context.priorObservedAt ?? input.observedAt, at: input.now)
            if let oldRule = sampling.ruleID, oldRule != context.ruleID {
                sampling = SamplingForecastReminderPolicy.ruleChanged(state: sampling,
                    at: context.ruleEffectiveAt ?? input.now)
            }
            sampling.ruleID = context.ruleID
            let result = SamplingForecastReminderPolicy.evaluate(state: sampling, sampleID: input.sampleID,
                observedAt: input.observedAt, now: input.now, remaining: input.remainingBytes,
                required: input.forecastRequiredBytes,
                eligible: p.forecastEnabled && usageValid && input.forecastEligible,
                scheduledBoundary: context.scheduledBoundary, resumePending: input.resumeSamplingCandidate)
            state.samplingForecastState = result.state
            state.forecastTrigger = nil; state.forecastRecovery = nil
            if result.shouldNotify {
                reasons.append(ReminderReason(kind: .forecast, forecastRiskID: result.state.riskID))
            }
        } else if input.samplingForecast == nil {
            if p.forecastEnabled, usageValid, input.forecastEligible, let remaining, remaining > 0,
               let required = finiteNonnegative(input.forecastRequiredBytes) {
                advance(&state.forecastRecovery, condition: required <= 0.90 * remaining,
                        criterion: "forecastRecovery", input: input, isNew: newSample)
                if state.forecastRecovery?.confirmed == true {
                    state.forecastNotified = false; state.forecastRecovery = nil; state.forecastTrigger = nil
                }
                let trigger = required >= 1.10 * remaining && cooldownPassed(state.forecastLastAcceptedAt, at: input.now)
                    && freshAfterCooldown(state.forecastLastAcceptedAt, observedAt: input.observedAt)
                advance(&state.forecastTrigger, condition: trigger, criterion: "forecastTrigger", input: input, isNew: newSample)
                if state.forecastTrigger?.confirmed == true, !state.forecastNotified {
                    reasons.append(ReminderReason(kind: .forecast))
                }
            } else {
                state.forecastTrigger = nil; state.forecastRecovery = nil
            }

        }

        if p.expiryEnabled, (2...30).contains(p.expiryLeadDays), let expiry = input.expiry,
           expiry.timeIntervalSince1970.isFinite {
            let distance = expiry.timeIntervalSince(input.now)
            let stage = distance <= 0 ? 3 : distance <= 86_400 ? 2 : distance <= Double(p.expiryLeadDays) * 86_400 ? 1 : 0
            let previous = state.expiryRecords.first { $0.expiry == expiry }?.highestStage ?? 0
            let kind: ReminderReason.Kind = stage == 3 ? .expired : stage == 2 ? .expiryDay : .expirySoon
            // A higher stage for this exact date may bypass same-stage cooldown caused by a recent correction.
            if stage > previous, stage > 0,
               (previous > 0 || state.latestExpiryStage.map { stage > $0 } == true
                || cooldownPassed(state.expiryLastAcceptedAt[kind.rawValue], at: input.now)) {
                reasons.append(ReminderReason(kind: kind, expiry: expiry, expiryUnverified: !input.usageFresh))
            }
        }
        let order = ReminderReason.Kind.allCases
        reasons.sort { order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! }
        return ReminderDecision(state: state, reasons: reasons)
    }

    /// Call only after the notification service has accepted the persisted request identity.
    public static func markAccepted(_ reasons: [ReminderReason], at date: Date, state original: ReminderState) -> ReminderState {
        var state = original
        for reason in reasons {
            switch reason.kind {
            case .low:
                state.lowNotified = true; state.lowLastAcceptedAt = date
            case .exhausted:
                // Direct exhaustion subsumes the lower-level low notification for this event.
                state.lowNotified = true; state.exhaustedNotified = true; state.lowLastAcceptedAt = date
            case .forecast:
                if let risk = reason.forecastRiskID, let sampling = state.samplingForecastState {
                    state.samplingForecastState = SamplingForecastReminderPolicy.markAccepted(state: sampling, riskID: risk, at: date)
                } else if reason.forecastRiskID == nil {
                    state.forecastNotified = true; state.forecastLastAcceptedAt = date
                    // A pre-upgrade unresolved request has no risk identity.
                    // Conservatively reserve the current migrated risk.
                    if var sampling = state.samplingForecastState {
                        sampling.notified = true
                        sampling.lastAcceptedAt = date
                        sampling.pendingSampleID = nil
                        sampling.pendingAuthorized = nil
                        state.samplingForecastState = sampling
                    }
                }
            case .expirySoon, .expiryDay, .expired:
                guard let expiry = reason.expiry else { continue }
                let stage = reason.kind == .expired ? 3 : reason.kind == .expiryDay ? 2 : 1
                if let index = state.expiryRecords.firstIndex(where: { $0.expiry == expiry }) {
                    state.expiryRecords[index].highestStage = max(stage, state.expiryRecords[index].highestStage)
                } else {
                    state.expiryRecords.append(ReminderExpiryRecord(expiry: expiry, highestStage: stage))
                }
                state.expiryLastAcceptedAt[reason.kind.rawValue] = date
                state.latestExpiryStage = stage
            }
        }
        return state
    }

    private static func advance(_ confirmation: inout ReminderConfirmation?, condition: Bool, criterion: String,
                                input: ReminderInput, isNew: Bool) {
        guard condition else { confirmation = nil; return }
        if confirmation?.criterion != criterion { confirmation = nil }
        guard isNew, let id = input.sampleID, let observedAt = input.observedAt else { return }
        guard var previous = confirmation else {
            confirmation = ReminderConfirmation(firstSampleID: id, firstObservedAt: observedAt, criterion: criterion)
            return
        }
        if id != previous.firstSampleID, observedAt.timeIntervalSince(previous.firstObservedAt) >= confirmationInterval {
            previous.confirmed = true; confirmation = previous
        }
    }

    private static func clearConfirmations(_ state: inout ReminderState) {
        state.lowRecovery = nil; state.exhaustionRecovery = nil
        state.forecastTrigger = nil; state.forecastRecovery = nil
        state.samplingForecastState?.recoverySampleID = nil
        state.samplingForecastState?.pendingSampleID = nil
        state.samplingForecastState?.pendingAuthorized = nil
    }
    private static func finiteNonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }; return value
    }
    private static func finitePositive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }; return value
    }
    private static func cooldownPassed(_ last: Date?, at date: Date) -> Bool {
        last.map { date.timeIntervalSince($0) >= cooldown } ?? true
    }
    private static func freshAfterCooldown(_ last: Date?, observedAt: Date?) -> Bool {
        guard let last else { return true }
        return observedAt.map { $0.timeIntervalSince(last) >= cooldown } ?? false
    }
}

/// Sparse-sampling candidate rule. A candidate is not evidence of delivery.
public enum SamplingForecastReminderPolicy {
    public struct State: Codable, Equatable, Sendable {
        public var notified: Bool
        public var lastSampleID: UUID?
        public var lastObservedAt: Date?
        public var recoverySampleID: UUID?
        public var riskID: UUID
        public var trackingSince: Date?
        public var cycleBoundary: Date?
        public var lastAcceptedAt: Date?
        public var pendingSampleID: UUID?
        /// True only after permission was checked while this candidate was pending.
        public var pendingAuthorized: Bool?
        public var ruleID: UUID?
        public init(notified: Bool = false, lastSampleID: UUID? = nil,
                    lastObservedAt: Date? = nil, recoverySampleID: UUID? = nil) {
            self.notified = notified
            self.lastSampleID = lastSampleID
            self.lastObservedAt = lastObservedAt
            self.recoverySampleID = recoverySampleID
            self.riskID = UUID()
            self.trackingSince = nil
            self.cycleBoundary = nil
            self.lastAcceptedAt = nil
            self.pendingSampleID = nil
            self.pendingAuthorized = nil
            self.ruleID = nil
        }
    }

    public struct Result: Equatable, Sendable {
        public var state: State
        /// This is a candidate, not evidence that a notification was delivered.
        public var shouldNotify: Bool
    }

    public static func evaluate(state original: State, sampleID: UUID?, observedAt: Date?, now: Date,
                                remaining: Double?, required: Double?, eligible: Bool,
                                scheduledBoundary: Date? = nil,
                                resumePending: Bool = false) -> Result {
        var state = original
        guard eligible, let id = sampleID, let date = observedAt, date <= now,
              let remaining, remaining.isFinite, remaining > 0,
              let required, required.isFinite, required >= 0 else {
            state.recoverySampleID = nil
            state.pendingSampleID = nil
            state.pendingAuthorized = nil
            if let id = sampleID, let date = observedAt, date <= now,
               state.lastObservedAt.map({ date > $0 }) ?? true {
                state.lastSampleID = id
                state.lastObservedAt = date
            }
            return Result(state: state, shouldNotify: false)
        }
        // A pending candidate belongs to the observation's cycle. A scheduled
        // reset after that observation invalidates it even before a new sample.
        if let boundary = scheduledBoundary, boundary > date, boundary <= now {
            state.pendingSampleID = nil
            state.pendingAuthorized = nil
            state.recoverySampleID = nil
            return Result(state: state, shouldNotify: false)
        }
        if resumePending, state.pendingSampleID == id, !state.notified,
           required / remaining >= 1.10 {
            return Result(state: state, shouldNotify: true)
        }
        guard id != state.lastSampleID,
              state.lastObservedAt.map({ date > $0 }) ?? true else {
            return Result(state: state, shouldNotify: false)
        }
        state.lastSampleID = id
        state.lastObservedAt = date
        state.pendingSampleID = nil
        state.pendingAuthorized = nil
        if state.trackingSince == nil { state.trackingSince = date }
        if let boundary = scheduledBoundary, let trackingSince = state.trackingSince,
           boundary > trackingSince, boundary <= date,
           state.cycleBoundary.map({ boundary > $0 }) ?? true {
            state.cycleBoundary = boundary
            state.riskID = UUID()
            state.notified = false
            state.recoverySampleID = nil
        }
        if state.notified {
            if required / remaining <= 0.90 {
                if state.recoverySampleID != nil {
                    state.notified = false
                    state.riskID = UUID()
                    state.recoverySampleID = nil
                } else {
                    state.recoverySampleID = id
                }
            } else {
                state.recoverySampleID = nil
            }
            return Result(state: state, shouldNotify: false)
        }
        state.recoverySampleID = nil
        let cooldownPassed = state.lastAcceptedAt.map {
            date.timeIntervalSince($0) >= ReminderPolicy.cooldown && now.timeIntervalSince($0) >= ReminderPolicy.cooldown
        } ?? true
        let shouldNotify = cooldownPassed && required / remaining >= 1.10
        if shouldNotify { state.pendingSampleID = id }
        return Result(state: state, shouldNotify: shouldNotify)
    }

    /// Conservative migration does not infer a previously elapsed boundary.
    public static func migrate(notified: Bool, lastAcceptedAt: Date?, latestSampleID: UUID?,
                               latestObservedAt: Date?, at date: Date) -> State {
        var state = State(notified: notified, lastSampleID: latestSampleID, lastObservedAt: latestObservedAt)
        state.lastAcceptedAt = lastAcceptedAt
        state.trackingSince = date
        return state
    }

    /// A rule edit is not a new cycle. Only a later scheduled boundary can rearm it.
    public static func ruleChanged(state original: State, at date: Date) -> State {
        var state = original
        state.trackingSince = date
        state.cycleBoundary = nil
        state.recoverySampleID = nil
        state.pendingSampleID = nil
        state.pendingAuthorized = nil
        return state
    }

    /// Cancel a pending candidate without treating it as delivered.
    public static func cancelPending(state original: State) -> State {
        var state = original
        state.pendingSampleID = nil
        state.pendingAuthorized = nil
        return state
    }

    /// Late acknowledgements cannot modify a subsequently rearmed risk.
    public static func markAccepted(state original: State, riskID: UUID, at date: Date) -> State {
        var state = original
        guard state.riskID == riskID else { return state }
        state.notified = true
        state.pendingSampleID = nil
        state.pendingAuthorized = nil
        state.lastAcceptedAt = date
        return state
    }
}
