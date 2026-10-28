import Foundation

/// Rounded bounds shared by the plot and its labels, in the selected display unit.
public struct BalanceAxisScale {
    public let lowerBytes: Double
    public let upperBytes: Double
    public let lowerLabel: String
    public let upperLabel: String

    public init(lowerBytes: Double, upperBytes: Double, unit: TrafficUnit) {
        let low = max(0, lowerBytes / unit.divisor)
        let high = max(low + 1 / unit.divisor, upperBytes / unit.divisor)
        let step = pow(10, floor(log10(high - low)) - 1)
        let lower = floor(low / step) * step
        let upper = ceil(high / step) * step
        self.lowerBytes = lower * unit.divisor
        self.upperBytes = upper * unit.divisor
        let decimals = max(0, Int(-floor(log10(step))))
        func label(_ value: Double) -> String {
            if value == 0 { return "0" }
            // Tiny balances must remain distinguishable without overflowing the axis.
            if abs(value) < 0.001 || abs(value) >= 100_000 {
                let precision = max(0, Int(floor(log10(abs(value))) - floor(log10(step))))
                return String(format: "%.*e", precision, value)
            }
            return String(format: "%.*f", min(3, decimals), value)
        }
        self.lowerLabel = label(lower)
        self.upperLabel = label(upper)
    }
}
