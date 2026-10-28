import Foundation

public enum TrafficError: Error, LocalizedError {
    case invalidURL, missingHeader, invalidHeader, status(Int), network(Int), storage, clock, invalidReset
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "请输入有效的 HTTPS 订阅链接（不支持明文 HTTP）。"
        case .missingHeader: return "服务器未返回 subscription-userinfo。请确认此链接支持流量信息，或稍后重试。"
        case .invalidHeader: return "订阅流量信息格式无效；已保留上次成功的数据。"
        case .status(let code): return "订阅服务器返回 HTTP \(code)；已保留上次数据。"
        case .network(let code): return "同步失败（网络错误 \(code)）。请检查网络、证书和订阅有效性。"
        case .storage: return "无法读取或保存本地历史。请检查磁盘空间和文件权限。"
        case .clock: return "系统时间早于上次采样，请检查时间设置后重试。"
        case .invalidReset: return "重置日期、时间或时区无效，请检查重置设置。"
        }
    }
}

public struct Subscription: Codable, Equatable, Sendable {
    public let upload: UInt64
    public let download: UInt64
    public let total: UInt64
    public let expiry: Date?
    public var used: UInt64 { upload + download }
    public var remaining: UInt64? { total == 0 ? nil : (used >= total ? 0 : total - used) }
    public var fraction: Double { total == 0 ? 0 : min(1, Double(used) / Double(total)) }

    public init(upload: UInt64, download: UInt64, total: UInt64, expiry: Date? = nil) throws {
        guard !upload.addingReportingOverflow(download).overflow else { throw TrafficError.invalidHeader }
        self.upload = upload; self.download = download; self.total = total; self.expiry = expiry
    }

    public static func parse(_ header: String) throws -> Subscription {
        var fields: [String: String] = [:]
        for piece in header.split(separator: ";") {
            let pair = piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { throw TrafficError.invalidHeader }
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard fields[key] == nil else { throw TrafficError.invalidHeader }
            fields[key] = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func number(_ key: String) throws -> UInt64 {
            guard let text = fields[key], !text.isEmpty,
                  text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = UInt64(text) else {
                throw TrafficError.invalidHeader
            }
            return value
        }
        let upload = try number("upload"), download = try number("download"), total = try number("total")
        var expiry: Date?
        if fields["expire"] != nil {
            let value = try number("expire")
            guard value <= 253402300799 else { throw TrafficError.invalidHeader }
            if value > 0 { expiry = Date(timeIntervalSince1970: Double(value)) }
        }
        return try Subscription(upload: upload, download: download, total: total, expiry: expiry)
    }

    public static func validatedURL(_ text: String) throws -> URL {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil,
              let url = components.url else { throw TrafficError.invalidURL }
        return url
    }
}

public enum TrafficFormat {
    /// Decimal GB, matching the visible GB label (not GiB).
    public static func gb(_ bytes: UInt64) -> String {
        String(format: "%.2f GB", Double(bytes) / 1_000_000_000)
    }
}
