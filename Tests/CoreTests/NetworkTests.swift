import Foundation
import XCTest
@testable import TrafficCore

private final class FixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        if path == "/offline" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        let needsCompatibleAgent = path == "/compatibility" && request.value(forHTTPHeaderField: "User-Agent") != "Clash/1.0"
        let headers = path == "/missing" || needsCompatibleAgent ? [:] : ["Subscription-Userinfo": path == "/malformed" ? "upload=invalid" : "upload=100;download=200;total=1000"]
        let response = HTTPURLResponse(url: request.url!, statusCode: path == "/unauthorized" ? 401 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("fixture node list; must never be parsed".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class CancellationFixture: @unchecked Sendable {
    let started = XCTestExpectation(description: "request waiting for headers")
    let stopped = XCTestExpectation(description: "transport stopped")
    let missingFirst: Bool
    private let lock = NSLock()
    private var agents: [String] = []
    init(missingFirst: Bool = false) { self.missingFirst = missingFirst }
    func record(_ request: URLRequest) -> Bool {
        lock.lock()
        agents.append(request.value(forHTTPHeaderField: "User-Agent") ?? "")
        let sendMissing = missingFirst && agents.count == 1
        lock.unlock()
        return sendMissing
    }
    var userAgents: [String] {
        lock.lock(); defer { lock.unlock() }; return agents
    }
}

private final class CancellationProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var fixtures: [String: CancellationFixture] = [:]
    private let stateLock = NSLock()
    private var holding = false
    static func register(_ fixture: CancellationFixture) -> URL {
        let key = UUID().uuidString
        lock.lock(); fixtures[key] = fixture; lock.unlock()
        return URL(string: "https://example.invalid/\(key)")!
    }
    static func remove(_ url: URL) {
        lock.lock(); fixtures.removeValue(forKey: url.lastPathComponent); lock.unlock()
    }
    private var fixture: CancellationFixture? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return Self.fixtures[request.url!.lastPathComponent]
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture else { return }
        let shouldHold = !fixture.record(request)
        stateLock.lock(); holding = shouldHold; stateLock.unlock()
        if shouldHold {
            fixture.started.fulfill()
        } else {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {
        stateLock.lock(); let wasHolding = holding; holding = false; stateLock.unlock()
        if wasHolding { fixture?.stopped.fulfill() }
    }
}

final class NetworkTests: XCTestCase {
    private let gateRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var gate: SubscriptionRequestGate { SubscriptionRequestGate(storeURL: gateRoot.appendingPathComponent("requests.json")) }
    override func tearDown() { try? FileManager.default.removeItem(at: gateRoot); super.tearDown() }
    private var cancellationConfiguration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CancellationProtocol.self]
        return config
    }
    private func fetch(_ path: String) async throws -> Subscription {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        return try await SubscriptionClient(configuration: config, gate: gate).fetch(URL(string: "https://example.invalid\(path)")!)
    }
    func testParsesHeadersAndIgnoresBody() async throws {
        let info = try await fetch("/success")
        XCTAssertEqual(info.remaining, 700)
    }
    func testUsesCompatibleAgentOnTheSingleRequest() async throws {
        let info = try await fetch("/compatibility")
        XCTAssertEqual(info.remaining, 700)
    }
    func testMissingHeader() async {
        do { _ = try await fetch("/missing"); XCTFail("Expected missing header") }
        catch TrafficError.missingHeader {} catch { XCTFail("Unexpected error") }
    }
    func testMalformedHeaderIsNotTreatedAsMissing() async {
        do { _ = try await fetch("/malformed"); XCTFail("Expected malformed header") }
        catch TrafficError.invalidHeader {} catch { XCTFail("Unexpected error") }
    }
    func testHTTPErrorIsSanitized() async {
        do { _ = try await fetch("/unauthorized"); XCTFail("Expected HTTP error") }
        catch TrafficError.status(let code) { XCTAssertEqual(code, 401) }
        catch { XCTFail("Unexpected error") }
    }
    func testNetworkErrorIsSanitized() async {
        do { _ = try await fetch("/offline"); XCTFail("Expected network error") }
        catch TrafficError.network(let code) { XCTAssertEqual(code, URLError.notConnectedToInternet.rawValue) }
        catch { XCTFail("Unexpected error") }
    }

    func testFailedRequestCannotRetryAfterClientRecreation() async {
        do { _ = try await fetch("/offline"); XCTFail("Expected network error") } catch {}
        do { _ = try await fetch("/offline"); XCTFail("Expected cooldown") }
        catch is SubscriptionCooldown {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testAlreadyCancelledTaskDoesNotStartTransport() async {
        let fixture = CancellationFixture()
        let url = CancellationProtocol.register(fixture)
        defer { CancellationProtocol.remove(url) }
        let client = SubscriptionClient(configuration: cancellationConfiguration, gate: gate)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.fetch(url)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(fixture.userAgents.isEmpty)
    }

    func testCancellationBeforeContinuationInstallationAndLateCallbacks() async {
        let fixture = CancellationFixture()
        let url = CancellationProtocol.register(fixture)
        defer { CancellationProtocol.remove(url) }
        let attempt = SubscriptionRequest(configuration: cancellationConfiguration)
        attempt.cancel()
        do { _ = try await attempt.fetch(url, userAgent: "test"); XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        // The delegate may deliver headers or completion after cancellation.
        // Neither is allowed to resolve the continuation a second time.
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let transport = session.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Subscription-Userinfo": "upload=100;download=200;total=1000"])!
        attempt.urlSession(session, dataTask: transport, didReceive: response) { disposition in
            XCTAssertEqual(disposition, .cancel)
        }
        attempt.urlSession(session, task: transport, didCompleteWithError: URLError(.cancelled))
        attempt.cancel()
        XCTAssertTrue(fixture.userAgents.isEmpty)
    }

    func testCancellationStopsTransportWithoutFallback() async {
        await checkTransportCancellation(missingFirst: false)
    }

    func testMissingHeaderDoesNotRetryWithAnotherAgent() async {
        let fixture = CancellationFixture(missingFirst: true)
        let url = CancellationProtocol.register(fixture)
        defer { CancellationProtocol.remove(url) }
        do {
            _ = try await SubscriptionClient(configuration: cancellationConfiguration, gate: gate).fetch(url)
            XCTFail("Expected missing header")
        } catch TrafficError.missingHeader {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(fixture.userAgents, ["Clash/1.0"])
    }

    private func checkTransportCancellation(missingFirst: Bool) async {
        let fixture = CancellationFixture(missingFirst: missingFirst)
        let url = CancellationProtocol.register(fixture)
        defer { CancellationProtocol.remove(url) }
        let client = SubscriptionClient(configuration: cancellationConfiguration, gate: gate)
        let task = Task { try await client.fetch(url) }
        await fulfillment(of: [fixture.started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        await fulfillment(of: [fixture.stopped], timeout: 2)
        XCTAssertEqual(fixture.userAgents, ["Clash/1.0"])
        do { _ = try await client.fetch(url); XCTFail("Cancelled request must retain cooldown") }
        catch is SubscriptionCooldown {} catch { XCTFail("Unexpected error: \(error)") }
        // Cancellation is per request and does not poison later refreshes.
        do { let info = try await fetch("/success"); XCTAssertEqual(info.remaining, 700) }
        catch { XCTFail("Next request failed: \(error)") }
    }
}
