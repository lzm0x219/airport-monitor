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

public struct ReminderReason: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case exhausted, expired, expiryDay, low, forecast, expirySoon
    }
    public var kind: Kind
    public var expiry: Date?
    public var expiryUnverified: Bool
    public init(kind: Kind, expiry: Date? = nil, expiryUnverified: Bool = false) {
        self.kind = kind; self.expiry = expiry; self.expiryUnverified = expiryUnverified
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
                state.forecastNotified = true; state.forecastLastAcceptedAt = date
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
