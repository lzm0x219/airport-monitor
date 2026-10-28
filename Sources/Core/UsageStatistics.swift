import Foundation

public enum UsageStatisticsRange: Int, CaseIterable, Sendable {
    case week = 7, month = 30, cycle = 0

    /// Cycle boundaries retain the rule's exact instant, even when its time zone
    /// differs from the statistics calendar. No previous boundary means unknown.
    public func period(at now: Date, calendar: Calendar, rule: ResetRule) -> DateInterval? {
        if self == .cycle {
            guard let start = rule.window(at: now).previous, start <= now else { return nil }
            return DateInterval(start: start, end: now)
        }
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: 1 - rawValue, to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
        return DateInterval(start: start, end: end)
    }
}

/// A nil date denotes the initial rule. Later versions never reinterpret earlier intervals.
public struct StatisticsRuleRevision: Sendable, Equatable {
    public let effectiveAt: Date?
    public let rule: ResetRule
    public init(effectiveAt: Date?, rule: ResetRule) {
        self.effectiveAt = effectiveAt
        self.rule = rule
    }
}

public enum UsageIntervalReason: String, Sendable, Equatable {
    case comparable, invalidTime, counterRollback, quotaChanged, knownReset, ruleChanged
}

/// Derived from two original sample identities; rebuilding reports does not create new intervals.
public struct UsageInterval: Identifiable, Sendable, Equatable {
    public var id: String { "\(beforeSampleID.uuidString)/\(afterSampleID.uuidString)" }
    public let beforeSampleID: UUID
    public let afterSampleID: UUID
    public let start: Date
    public let end: Date
    public let bytes: Double?
    public let reason: UsageIntervalReason
    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public var canCompare: Bool { reason == .comparable }
}

public struct DailyUsageObservation: Identifiable, Sendable {
    public var id: Date { period.start }
    public var date: Date { period.start }
    public let period: DateInterval
    /// Nil means no attributable observation, while zero means an observed zero increment.
    public let bytes: Double?
    public let intervals: Int
    public let hasUnallocated: Bool
    public let hasExcluded: Bool
}

public struct UsageReport: Sendable {
    public let period: DateInterval
    public let summary: UsageSummary
    public let daily: [DailyUsageObservation]
    public let unallocated: [UsageInterval]
    public let excluded: [UsageInterval]
    /// Comparable intervals only partly inside the filter; never prorated or included in its sum.
    public let partial: [UsageInterval]
    public let observedStart: Date?
    public let observedEnd: Date?
    public var bytes: Double? { summary.intervals == 0 ? nil : summary.bytes }
    public var unallocatedBytes: Double? {
        unallocated.isEmpty ? nil : unallocated.reduce(0) { $0 + ($1.bytes ?? 0) }
    }
}

public extension Ledger {
    func observedIntervals(rule: ResetRule, revisions: [StatisticsRuleRevision] = []) -> [UsageInterval] {
        // Stable ordering makes equal-effective-time versions deterministic: the last supplied wins.
        let ordered = revisions.enumerated().sorted {
            let lhs = $0.element.effectiveAt ?? .distantPast
            let rhs = $1.element.effectiveAt ?? .distantPast
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
        var checkedRule: ResetRule?
        var checker: ResetIntervalChecker?
        return zip(samples, samples.dropFirst()).map { before, after in
            let reason: UsageIntervalReason
            let activeRule = ordered.last { ($0.effectiveAt ?? .distantPast) <= before.date }?.rule
                ?? (ordered.isEmpty ? rule : ResetRule())
            if checkedRule != activeRule {
                checkedRule = activeRule
                checker = ResetIntervalChecker(rule: activeRule)
            }
            if !before.date.timeIntervalSince1970.isFinite || !after.date.timeIntervalSince1970.isFinite ||
                after.date <= before.date {
                reason = .invalidTime
            } else if after.subscription.upload < before.subscription.upload ||
                        after.subscription.download < before.subscription.download {
                reason = .counterRollback
            } else if after.subscription.total != before.subscription.total {
                reason = .quotaChanged
            } else if ordered.contains(where: {
                guard let effective = $0.effectiveAt else { return false }
                // A completed interval ending exactly at an edit keeps the rule that observed it.
                return before.date < effective && effective < after.date
            }) {
                reason = .ruleChanged
            } else if checker?.crosses(before.date, after.date) == true {
                reason = .knownReset
            } else {
                reason = .comparable
            }
            // Subtract integer components before converting: tiny deltas at large counters survive.
            let bytes: Double? = reason == .comparable
                ? Double(after.subscription.upload - before.subscription.upload)
                    + Double(after.subscription.download - before.subscription.download)
                : nil
            return UsageInterval(beforeSampleID: before.id, afterSampleID: after.id,
                                 start: before.date, end: after.date, bytes: bytes, reason: reason)
        }
    }

    func usageReport(in period: DateInterval, calendar: Calendar, rule: ResetRule = ResetRule(),
                     revisions: [StatisticsRuleRevision] = []) -> UsageReport {
        guard period.duration > 0 else { return emptyUsageReport(in: period) }
        return ObservationAnalysis(ledger: self, rule: rule, revisions: revisions)
            .usageReport(in: period, calendar: calendar)
    }
}

private func emptyUsageReport(in period: DateInterval) -> UsageReport {
    UsageReport(period: period,
        summary: UsageSummary(bytes: 0, intervals: 0, excludedIntervals: 0), daily: [],
        unallocated: [], excluded: [], partial: [], observedStart: nil, observedEnd: nil)
}

public extension ObservationAnalysis {
    func usageReport(in period: DateInterval, calendar: Calendar) -> UsageReport {
        guard period.duration > 0 else {
            return emptyUsageReport(in: period)
        }
        let relevant = intervals.filter {
            if $0.duration <= 0 {
                return $0.end >= period.start && $0.end < period.end
            }
            return $0.end > period.start && $0.start < period.end
        }
        let excluded = relevant.filter { !$0.canCompare }
        let partial = relevant.filter { $0.canCompare && ($0.start < period.start || $0.end > period.end) }
        let included = relevant.filter { $0.canCompare && $0.start >= period.start && $0.end <= period.end }
        func attributedDay(_ interval: UsageInterval) -> Date? {
            guard let day = calendar.dateInterval(of: .day, for: interval.start), interval.end <= day.end else { return nil }
            return day.start
        }
        var assignedDays: [Date: [UsageInterval]] = [:]
        var unallocated: [UsageInterval] = []
        for interval in included {
            if let day = attributedDay(interval) { assignedDays[day, default: []].append(interval) }
            else { unallocated.append(interval) }
        }
        let crossDay = relevant.filter { $0.canCompare && attributedDay($0) == nil }
        // Date arithmetic follows the explicit statistics calendar, including 23/25-hour days.
        var daily: [DailyUsageObservation] = []
        var cursor = calendar.startOfDay(for: period.start)
        while cursor < period.end, let day = calendar.dateInterval(of: .day, for: cursor), day.end > cursor {
            let assigned = assignedDays[day.start] ?? []
            let touches: (UsageInterval) -> Bool = { $0.end > day.start && $0.start < day.end }
            daily.append(DailyUsageObservation(period: day,
                bytes: assigned.isEmpty ? nil : assigned.reduce(0) { $0 + ($1.bytes ?? 0) },
                intervals: assigned.count,
                hasUnallocated: crossDay.contains(where: touches),
                hasExcluded: excluded.contains(where: touches) || partial.contains(where: touches)))
            cursor = day.end
        }
        let observed = samples.filter { $0.date >= period.start && $0.date <= period.end }.map(\.date)
        return UsageReport(period: period,
            summary: UsageSummary(bytes: included.reduce(0) { $0 + ($1.bytes ?? 0) },
                                  intervals: included.count, excludedIntervals: excluded.count + partial.count),
            daily: daily, unallocated: unallocated, excluded: excluded, partial: partial,
            observedStart: observed.min(), observedEnd: observed.max())
    }
}
