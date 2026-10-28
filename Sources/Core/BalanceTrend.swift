import Foundation

public struct BalancePoint: Equatable, Sendable {
    public let date: Date
    public let bytes: Double
}

public struct BalanceTrend: Sendable {
    public let recorded: [[BalancePoint]]
    public let projected: [BalancePoint]
    public let start: Date
    public let end: Date
    public let lowerBytes: Double
    public let upperBytes: Double
    public let forecast: ForecastResult
}

public extension Ledger {
    /// A balance sparkline, with gaps and resets left disconnected. Forecast
    /// eligibility is shared with the existing estimator, never inferred here.
    func balanceTrend(at now: Date, rule: ResetRule, intervalMinutes: Int,
                      calendar: Calendar, synchronizationFailed: Bool = false,
                      availability: ForecastAvailability = .init(),
                      revisions: [StatisticsRuleRevision] = []) -> BalanceTrend {
        ObservationAnalysis(ledger: self, rule: rule, revisions: revisions)
            .balanceTrend(at: now, intervalMinutes: intervalMinutes, calendar: calendar,
                          synchronizationFailed: synchronizationFailed, availability: availability)
    }
}

public extension ObservationAnalysis {
    func balanceTrend(at now: Date, intervalMinutes: Int, calendar: Calendar,
                      synchronizationFailed: Bool = false,
                      availability: ForecastAvailability = .init()) -> BalanceTrend {
        let result = forecast(at: now, intervalMinutes: intervalMinutes,
                              calendar: calendar, synchronizationFailed: synchronizationFailed,
                              availability: availability)
        let cutoff = now.addingTimeInterval(-7 * 86400)
        let maximumGap = Double(max(1, intervalMinutes)) * 120
        let intervalsBySample = Dictionary(uniqueKeysWithValues: intervals.map { ($0.afterSampleID, $0) })
        var segments: [[BalancePoint]] = []
        var previous: Sample?
        for sample in samples where sample.date >= cutoff && sample.date <= now {
            guard let remaining = sample.subscription.remaining else { previous = nil; continue }
            let point = BalancePoint(date: sample.date, bytes: Double(remaining))
            let connected = previous.map {
                guard let interval = intervalsBySample[sample.id] else { return false }
                return interval.beforeSampleID == $0.id && interval.canCompare &&
                    interval.duration <= maximumGap
            } ?? false
            if connected, !segments.isEmpty { segments[segments.count - 1].append(point) }
            else { segments.append([point]) }
            previous = sample
        }

        var projected: [BalancePoint] = []
        var end = now
        if let estimate = result.estimate, let latest = samples.last, let remaining = latest.subscription.remaining,
           remaining > 0 {
            let horizon = latest.date.addingTimeInterval(7 * 86400)
            end = [horizon, estimate.boundary, estimate.exhaustion].compactMap { $0 }.min() ?? now
            if end > latest.date {
                projected = [BalancePoint(date: latest.date, bytes: Double(remaining)),
                             BalancePoint(date: end, bytes: max(0, Double(remaining) -
                                estimate.dailyBytes * end.timeIntervalSince(latest.date) / 86400))]
            }
        }
        let values = segments.flatMap { $0.map(\.bytes) } + projected.map(\.bytes)
        let low = values.min() ?? 0, high = values.max() ?? 1
        let padding = max(1, max((high - low) * 0.12, high * 0.005))
        return BalanceTrend(recorded: segments, projected: projected,
            start: segments.first?.first?.date ?? now, end: max(now, end),
            lowerBytes: max(0, low - padding), upperBytes: high + padding, forecast: result)
    }
}
