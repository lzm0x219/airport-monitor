import Foundation

public enum ResetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, monthly, billing, once
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .none: return "未设置"
        case .monthly: return "每月固定日"
        case .billing: return "每月按购买日"
        case .once: return "指定下次时间"
        }
    }
}

/// User-supplied schedule, never inferred from subscription expiry or a rollback.
public struct ResetRule: Codable, Equatable, Sendable {
    public var kind: ResetKind = .none
    public var day: Int = 1
    public var hour: Int = 0
    public var minute: Int = 0
    public var anchor: Date = Date()
    public var timeZoneID: String = TimeZone.current.identifier
    public init() {}
    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        return calendar
    }
    public func validate() throws {
        guard (1...31).contains(day), (0...23).contains(hour), (0...59).contains(minute),
              TimeZone(identifier: timeZoneID) != nil, anchor.timeIntervalSince1970.isFinite,
              (0...253402300799).contains(anchor.timeIntervalSince1970) else { throw TrafficError.invalidReset }
    }
    public func window(at date: Date) -> (previous: Date?, next: Date?) {
        guard (try? validate()) != nil, kind != .none else { return (nil, nil) }
        if kind == .once { return anchor <= date ? (anchor, nil) : (nil, anchor) }
        let cal = calendar
        let requestedDay = kind == .billing ? cal.component(.day, from: anchor) : day
        func event(in month: Date) -> Date? {
            guard let range = cal.range(of: .day, in: .month, for: month),
                  let dayDate = cal.date(byAdding: .day, value: min(requestedDay, range.count) - 1, to: month) else { return nil }
            // Missing DST times advance to the next valid time; repeated times use the first occurrence.
            return cal.date(bySettingHour: hour, minute: minute, second: 0, of: dayDate,
                            matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
        }
        guard let month = cal.dateInterval(of: .month, for: date)?.start else { return (nil, nil) }
        let firstBilling = cal.dateInterval(of: .month, for: anchor).flatMap { event(in: $0.start) }
        if kind == .billing, let firstBilling, firstBilling > date { return (nil, firstBilling) }
        let candidates = (-2...2).compactMap { cal.date(byAdding: .month, value: $0, to: month) }
            .compactMap(event).filter { kind != .billing || $0 >= (firstBilling ?? anchor) }.sorted()
        return (candidates.last(where: { $0 <= date }), candidates.first(where: { $0 > date }))
    }
    public func crosses(_ before: Date, _ after: Date) -> Bool {
        window(at: before).next.map { $0 <= after } ?? false
    }
}

/// Reuses a scheduled boundary while scanning chronological sample intervals.
/// An interval starting exactly at a reset belongs to the new cycle.
public struct ResetIntervalChecker {
    private let rule: ResetRule
    private var lastStart: Date?
    private var nextBoundary: Date?

    public init(rule: ResetRule) { self.rule = rule }

    public mutating func crosses(_ before: Date, _ after: Date) -> Bool {
        if (lastStart.map { before < $0 } ?? true) || nextBoundary.map({ before >= $0 }) == true {
            nextBoundary = rule.window(at: before).next
        }
        lastStart = before
        return nextBoundary.map { $0 <= after } ?? false
    }
}

public enum ForecastBoundary: Sendable, Equatable { case reset, expiry }
public struct ForecastEstimate: Sendable {
    public let dailyBytes: Double
    public let days: Int
    /// Fraction of the selected observation span accounted for by comparable
    /// intervals (currently 1). This is not a statistical confidence score.
    public let coverage: Double
    public let boundary: Date?
    public let boundaryKind: ForecastBoundary?
    public let remainingAtBoundary: Double?
    public let exhaustion: Date?
    public let runsOutBeforeBoundary: Bool
}
public enum ForecastReason: Sendable, Equatable {
    case noData, unlimited, expired, stale, insufficient, awaitingReset
}
/// More precise eligibility without breaking existing presentation switches.
public enum ForecastDiagnostic: Sendable, Equatable {
    case noData, unknownRemaining, expired, synchronizationFailed, paused, synchronizing
    case pendingVerification, resetRuleChanged, staleReading, futureReading
    case insufficientHistory, missingReset, awaitingReset, expiryBeforeReset, zeroGrowth
}
public struct ForecastAvailability: Sendable, Equatable {
    public var paused: Bool
    public var synchronizing: Bool
    public var pendingVerification: Bool
    public var resetRuleChanged: Bool
    public init(paused: Bool = false, synchronizing: Bool = false,
                pendingVerification: Bool = false, resetRuleChanged: Bool = false) {
        self.paused = paused; self.synchronizing = synchronizing
        self.pendingVerification = pendingVerification; self.resetRuleChanged = resetRuleChanged
    }
}
/// Display snapshots may use sparse subscription observations. Notification
/// callers keep the default continuous qualification.
public enum ForecastMode: Sendable { case continuous, samplingSnapshot }

public struct ForecastResult: Sendable {
    public let estimate: ForecastEstimate?
    public let reason: ForecastReason?
    public let eligibleDays: Int
    public let diagnostic: ForecastDiagnostic?
    public let generatedAt: Date
    public let observedFrom: Date?
    public let observedThrough: Date?
    public let sampleCount: Int
    public var observedSeconds: TimeInterval {
        guard let observedFrom, let observedThrough else { return 0 }
        return observedThrough.timeIntervalSince(observedFrom)
    }
}

public extension Ledger {
    /// Uses actual observations in the latest comparable sequence. Continuous
    /// mode retains its 7-day / 24-hour rules for reminders. Sampling snapshots
    /// must be evaluated at a successful reading, with cadence-sized coverage.
    /// Neither mode allocates missing days or interpolates a cutoff.
    func forecast(at now: Date, rule: ResetRule, intervalMinutes: Int,
                  calendar: Calendar, synchronizationFailed: Bool = false,
                  availability: ForecastAvailability = .init(),
                  revisions: [StatisticsRuleRevision] = [],
                  mode: ForecastMode = .continuous) -> ForecastResult {
        ObservationAnalysis(ledger: self, rule: rule, revisions: revisions)
            .forecast(at: now, intervalMinutes: intervalMinutes, calendar: calendar,
                      synchronizationFailed: synchronizationFailed, availability: availability, mode: mode)
    }
}

public extension ObservationAnalysis {
    func forecast(at now: Date, intervalMinutes: Int, calendar: Calendar,
                  synchronizationFailed: Bool = false, availability: ForecastAvailability = .init(),
                  mode: ForecastMode = .continuous) -> ForecastResult {
        let sampling = mode == .samplingSnapshot
        let cadence = Double(SubscriptionRefreshPolicy.normalized(intervalMinutes)) * 60
        let cutoff = now.addingTimeInterval(-(sampling ? max(28 * 86400, cadence * 6) : 7 * 86400))
        let maximumGap = sampling ? cadence * 2 : 86400
        let minimumSpan = sampling ? cadence * 3 : 72 * 3600
        var sequence = samples.last.map { [$0] } ?? []
        var bytes: Double = 0
        // Walk backward from the latest observation; never skip a break to find
        // an older, more convenient set of observations.
        if let latest = samples.last, latest.date >= cutoff, latest.date <= now {
            // A rule edit does not invalidate already completed usage intervals,
            // but the new forecast must accumulate observations under that rule.
            let latestRuleChange = revisions.compactMap(\.effectiveAt)
                .filter { $0 <= latest.date }.max() ?? .distantPast
            for (index, interval) in intervals.enumerated().reversed() {
                guard interval.end <= latest.date, interval.start >= cutoff,
                      interval.start >= latestRuleChange,
                      interval.canCompare, interval.duration <= maximumGap else { break }
                bytes += interval.bytes ?? 0
                sequence.append(samples[index])
            }
            sequence.reverse()
        } else { sequence = [] }
        let days = Set(sequence.map { calendar.startOfDay(for: $0.date) }).count
        let span = (sequence.last?.date.timeIntervalSince(sequence.first?.date ?? now)) ?? 0
        func result(_ estimate: ForecastEstimate? = nil, _ reason: ForecastReason? = nil,
                    _ diagnostic: ForecastDiagnostic? = nil) -> ForecastResult {
            ForecastResult(estimate: estimate, reason: reason, eligibleDays: days,
                           diagnostic: diagnostic, generatedAt: now,
                           observedFrom: sequence.first?.date, observedThrough: sequence.last?.date,
                           sampleCount: sequence.count)
        }
        guard let latest = samples.last else { return result(nil, .noData, .noData) }
        guard let remaining = latest.subscription.remaining else { return result(nil, .unlimited, .unknownRemaining) }
        if let expiry = latest.subscription.expiry, expiry <= now { return result(nil, .expired, .expired) }
        if synchronizationFailed { return result(nil, .stale, .synchronizationFailed) }
        if availability.paused { return result(nil, .stale, .paused) }
        if availability.synchronizing { return result(nil, .stale, .synchronizing) }
        if availability.pendingVerification { return result(nil, .stale, .pendingVerification) }
        if availability.resetRuleChanged { return result(nil, .insufficient, .resetRuleChanged) }
        if now < latest.date { return result(nil, .stale, .futureReading) }
        let staleAfter = SubscriptionRefreshPolicy.freshnessInterval(minutes: intervalMinutes)
        if now.timeIntervalSince(latest.date) > staleAfter { return result(nil, .stale, .staleReading) }
        let resetWindow = rule.window(at: now)
        if rule.kind == .once, resetWindow.next == nil { return result(nil, .awaitingReset, .awaitingReset) }
        if let scheduled = resetWindow.previous, latest.date < scheduled { return result(nil, .awaitingReset, .awaitingReset) }
        guard span >= minimumSpan, sequence.count >= 4, days >= 3 else {
            return result(nil, .insufficient, .insufficientHistory)
        }
        guard let boundary = resetWindow.next, boundary > now else {
            return result(nil, .awaitingReset, rule.kind == .once ? .awaitingReset : .missingReset)
        }
        if let expiry = latest.subscription.expiry, expiry <= boundary {
            return result(nil, .insufficient, .expiryBeforeReset)
        }
        guard bytes > 0 else { return result(nil, .insufficient, .zeroGrowth) }
        let daily = bytes / span * 86400
        let secondsLeft = Double(remaining) / daily * 86400
        // Avoid constructing dates outside the supported calendar range for negligible usage.
        let exhaustion = secondsLeft.isFinite && secondsLeft < 253402300799 - latest.date.timeIntervalSince1970
            ? latest.date.addingTimeInterval(secondsLeft) : nil
        let atBoundary = max(0, Double(remaining) - daily * boundary.timeIntervalSince(latest.date) / 86400)
        return result(ForecastEstimate(dailyBytes: daily, days: days,
            coverage: 1, boundary: boundary,
            boundaryKind: .reset, remainingAtBoundary: atBoundary, exhaustion: exhaustion,
            runsOutBeforeBoundary: exhaustion.map { $0 < boundary } ?? false))
    }
}
