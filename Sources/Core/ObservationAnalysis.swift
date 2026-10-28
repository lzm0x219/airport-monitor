import Foundation

/// An immutable interpretation of one ledger under one set of rule versions.
/// Calendar, clock and availability remain inputs to each derived calculation.
public struct ObservationAnalysis: Sendable {
    let samples: [Sample]
    let rule: ResetRule
    let revisions: [StatisticsRuleRevision]
    public let intervals: [UsageInterval]

    public init(ledger: Ledger, rule: ResetRule, revisions: [StatisticsRuleRevision] = []) {
        samples = ledger.samples
        self.rule = rule
        self.revisions = revisions
        intervals = ledger.observedIntervals(rule: rule, revisions: revisions)
    }
}
