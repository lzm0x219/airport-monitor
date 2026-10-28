import Foundation

public enum TrafficUnit: String, CaseIterable, Identifiable, Sendable {
    case gb, gib
    public var id: String { rawValue }
    public var label: String { self == .gb ? "GB" : "GiB" }
    public var divisor: Double { self == .gb ? 1_000_000_000 : 1_073_741_824 }
    public var explanation: String { self == .gb ? "十进制 · 1 GB = 10⁹ 字节" : "二进制 · 1 GiB = 2³⁰ 字节" }
    public func value(_ bytes: Double, decimals: Int = 2) -> String {
        String(format: "%.*f", decimals, bytes / divisor)
    }
    public func text(_ bytes: UInt64, decimals: Int = 2) -> String {
        "\(value(Double(bytes), decimals: decimals)) \(label)"
    }
    public func menuText(_ bytes: UInt64) -> String {
        if bytes == 0 { return "0 \(label)" }
        let base: Double = self == .gb ? 1000 : 1024
        if Double(bytes) >= divisor * base {
            return String(format: "%.1f %@", Double(bytes) / (divisor * base), self == .gb ? "TB" : "TiB")
        }
        if Double(bytes) >= divisor { return text(bytes, decimals: 1) }
        let mega = base * base
        if Double(bytes) >= mega { return String(format: "%.0f %@", Double(bytes) / mega, self == .gb ? "MB" : "MiB") }
        if Double(bytes) >= base { return String(format: "%.0f %@", Double(bytes) / base, self == .gb ? "KB" : "KiB") }
        return "\(bytes) B"
    }
}

public enum MenuDisplay: String, CaseIterable, Identifiable, Sendable {
    case iconAndBalance, balance, icon
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .iconAndBalance: return "图标与余额"
        case .balance: return "仅余额"
        case .icon: return "仅图标"
        }
    }
}
