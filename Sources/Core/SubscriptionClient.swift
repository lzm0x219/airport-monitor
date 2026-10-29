import Foundation
import CryptoKit
import Darwin

public enum SubscriptionRefreshPolicy {
    public static let minimumMinutes = 72 * 60
    public static let minimumInterval: TimeInterval = 72 * 3600
    public static func normalized(_ minutes: Int) -> Int { minutes == 7 * 24 * 60 ? minutes : minimumMinutes }
    // A provider's rate limit does not make a three-day-old balance current.
    public static func freshnessInterval(minutes: Int) -> TimeInterval {
        minutes >= minimumMinutes ? 1800 : max(1800, Double(max(1, minutes)) * 180)
    }
}

public struct SubscriptionCooldown: Error, LocalizedError {
    public let until: Date
    public init(until: Date) { self.until = until }
    public var errorDescription: String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "为避免订阅请求过于频繁，两次请求至少间隔72小时。下次可刷新：\(formatter.string(from: until))。"
    }
}

/// Persist BEFORE transport starts. Failed/cancelled requests also consume the
/// interval. A separate lock file serializes independent app processes.
public final class SubscriptionRequestGate: @unchecked Sendable {
    private enum LockContention: Error { case busy }
    public static let shared = SubscriptionRequestGate(storeURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SurgeTrafficMonitor/subscription-requests-v1.json"))
    private let storeURL: URL
    public init(storeURL: URL) { self.storeURL = storeURL }

    /// The same normalized, hashed identity used by the persistent gate.
    public static func identity(for url: URL) throws -> String {
        let validated = try Subscription.validatedURL(url.absoluteString)
        var components = URLComponents(url: validated, resolvingAgainstBaseURL: false)!
        components.fragment = nil; components.scheme = components.scheme?.lowercased(); components.host = components.host?.lowercased()
        if components.port == 443 { components.port = nil }
        if components.percentEncodedPath.isEmpty { components.percentEncodedPath = "/" }
        return SHA256.hash(data: Data(components.string!.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func nextAllowedDate(for url: URL, observedAttempt: Date? = nil, now: Date = Date()) throws -> Date? {
        try access(url, observedAttempt: observedAttempt, now: now, reserve: false)
    }

    /// UI callers must not wait on file locks or disk access on the main actor.
    public func nextAllowedDateAsync(for url: URL, observedAttempt: Date? = nil, now: Date = Date()) async throws -> Date? {
        while true {
            try Task.checkCancellation()
            let worker = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                return try self.access(url, observedAttempt: observedAttempt, now: now, reserve: false, nonblocking: true)
            }
            do {
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                return result
            } catch LockContention.busy {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    public func reserve(_ url: URL, now: Date = Date()) throws {
        if let until = try access(url, observedAttempt: nil, now: now, reserve: true) {
            throw SubscriptionCooldown(until: until)
        }
    }

    private func access(_ url: URL, observedAttempt: Date?, now: Date, reserve: Bool, nonblocking: Bool = false) throws -> Date? {
        guard now.timeIntervalSince1970.isFinite else { throw TrafficError.clock }
        let key = try Self.identity(for: url)
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let fd = open(storeURL.appendingPathExtension("lock").path, O_CREAT | O_RDWR, 0o600)
            guard fd >= 0 else { throw TrafficError.storage }
            defer { close(fd) }
            guard flock(fd, LOCK_EX | (nonblocking ? LOCK_NB : 0)) == 0 else {
                if nonblocking && (errno == EWOULDBLOCK || errno == EAGAIN) { throw LockContention.busy }
                throw TrafficError.storage
            }
            defer { flock(fd, LOCK_UN) }
            if nonblocking { try Task.checkCancellation() }
            var records: [String: Date] = [:]
            if FileManager.default.fileExists(atPath: storeURL.path) {
                records = try JSONDecoder().decode([String: Date].self, from: Data(contentsOf: storeURL))
                guard records.values.allSatisfy({ $0.timeIntervalSince1970.isFinite }) else { throw TrafficError.storage }
            }
            var changed = false
            if let observedAttempt, observedAttempt.timeIntervalSince1970.isFinite,
               records[key].map({ observedAttempt > $0 }) ?? true {
                records[key] = observedAttempt; changed = true
            }
            let until = records[key].map { $0.addingTimeInterval(SubscriptionRefreshPolicy.minimumInterval) }
            let blocked = until.flatMap { $0 > now ? $0 : nil }
            if reserve && blocked == nil { records[key] = now; changed = true }
            if changed {
                if nonblocking { try Task.checkCancellation() }
                try JSONEncoder().encode(records).write(to: storeURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
            }
            return blocked
        } catch is LockContention { throw LockContention.busy }
        catch is CancellationError { throw CancellationError() }
        catch { throw TrafficError.storage }
    }
}

/// A fresh ephemeral session per refresh; stops at headers, discarding the node-list body.
public final class SubscriptionClient: @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let gate: SubscriptionRequestGate
    private let now: () -> Date

    public init(configuration: URLSessionConfiguration = .ephemeral, gate: SubscriptionRequestGate = .shared, now: @escaping () -> Date = Date.init) {
        self.configuration = configuration
        self.gate = gate; self.now = now
    }

    public func fetch(_ url: URL) async throws -> Subscription {
        try Task.checkCancellation()
        try gate.reserve(url, now: now())
        // One request only: missing headers must not trigger a second user-agent
        // attempt. Clash is used initially for providers requiring that format.
        return try await request(url, userAgent: "Clash/1.0")
    }

    private func request(_ url: URL, userAgent: String) async throws -> Subscription {
        // Use a distinct delegate for each attempt. A cancelled first task can
        // complete after the fallback starts and must not finish its continuation.
        let attempt = SubscriptionRequest(configuration: configuration, gate: gate, now: now)
        do {
            let result = try await attempt.fetch(url, userAgent: userAgent)
            try Task.checkCancellation()
            return result
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }
}

final class SubscriptionRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    // Cancellation runs on the caller's executor; delegate callbacks run on the
    // session queue. One terminal result owns the continuation and session.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Subscription, Error>?
    private var session: URLSession?
    private var terminalResult: Result<Subscription, Error>?
    private var redirects = 0
    private let configuration: URLSessionConfiguration
    private let gate: SubscriptionRequestGate
    private let now: () -> Date

    init(configuration: URLSessionConfiguration, gate: SubscriptionRequestGate = .shared, now: @escaping () -> Date = Date.init) {
        self.configuration = configuration
        self.gate = gate; self.now = now
        super.init()
    }

    func fetch(_ url: URL, userAgent: String) async throws -> Subscription {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                start(url, userAgent: userAgent, continuation: continuation)
            }
        }, onCancel: {
            self.cancel()
        })
    }

    private func start(_ url: URL, userAgent: String,
                       continuation: CheckedContinuation<Subscription, Error>) {
        lock.lock()
        if let terminalResult {
            lock.unlock()
            continuation.resume(with: terminalResult)
        } else {
            self.continuation = continuation
            let config = configuration.copy() as! URLSessionConfiguration
            config.timeoutIntervalForRequest = 25
            config.timeoutIntervalForResource = 40
            config.urlCache = nil
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.session = session
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            session.dataTask(with: request).resume()
            lock.unlock()
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<Subscription, Error>) {
        lock.lock()
        guard terminalResult == nil else { lock.unlock(); return }
        terminalResult = result
        let continuation = self.continuation
        let session = self.session
        self.continuation = nil
        self.session = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.cancel)
        guard let response = response as? HTTPURLResponse else {
            finish(.failure(TrafficError.invalidHeader)); return
        }
        guard (200..<300).contains(response.statusCode) else {
            finish(.failure(TrafficError.status(response.statusCode))); return
        }
        guard let header = response.value(forHTTPHeaderField: "subscription-userinfo") else {
            finish(.failure(TrafficError.missingHeader)); return
        }
        do { finish(.success(try Subscription.parse(header))) }
        catch { finish(.failure(TrafficError.invalidHeader)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(TrafficError.network((error as NSError).code))) }
        else { finish(.failure(TrafficError.missingHeader)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        let active = terminalResult == nil
        redirects += 1
        let withinLimit = redirects <= 5
        lock.unlock()
        guard active else { completionHandler(nil); return }
        guard withinLimit, let url = request.url, (try? Subscription.validatedURL(url.absoluteString)) != nil else {
            completionHandler(nil); finish(.failure(TrafficError.invalidURL)); return
        }
        do { try gate.reserve(url, now: now()); completionHandler(request) }
        catch { completionHandler(nil); finish(.failure(error)) }
    }
}
