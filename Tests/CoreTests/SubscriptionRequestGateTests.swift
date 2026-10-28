import Foundation
import XCTest
@testable import TrafficCore

final class SubscriptionRequestGateTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var file: URL { root.appendingPathComponent("requests.json") }
    private var gate: SubscriptionRequestGate { SubscriptionRequestGate(storeURL: file) }
    private let url = URL(string: "https://example.invalid/subscription?token=private-test-value")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    override func tearDown() { try? FileManager.default.removeItem(at: root); super.tearDown() }

    func testBoundarySurvivesReopeningAndBlockedClicksDoNotExtendIt() throws {
        try gate.reserve(url, now: now)
        for hours in [0.0, 1, 48, 71.999] {
            XCTAssertThrowsError(try gate.reserve(url, now: now.addingTimeInterval(hours * 3600))) {
                XCTAssertEqual(($0 as? SubscriptionCooldown)?.until, self.now.addingTimeInterval(72 * 3600))
            }
        }
        try gate.reserve(url, now: now.addingTimeInterval(72 * 3600))
        XCTAssertEqual(try gate.nextAllowedDate(for: url, now: now.addingTimeInterval(72 * 3600)), now.addingTimeInterval(144 * 3600))
    }

    func testMigrationRetainsMostRecentAttemptAndNoSecretIsStored() throws {
        let last = now.addingTimeInterval(-3600)
        XCTAssertEqual(try gate.nextAllowedDate(for: url, observedAttempt: last, now: now), last.addingTimeInterval(72 * 3600))
        XCTAssertEqual(try gate.nextAllowedDate(for: url, observedAttempt: last.addingTimeInterval(-86400), now: now), last.addingTimeInterval(72 * 3600))
        let raw = try String(contentsOf: file)
        XCTAssertFalse(raw.contains("private-test-value")); XCTAssertFalse(raw.contains("example.invalid"))
    }

    func testSameURLAliasesShareLimitButDistinctSubscriptionsDoNot() throws {
        try gate.reserve(url, now: now)
        let alias = URL(string: "https://EXAMPLE.invalid:443/subscription?token=private-test-value#ignored")!
        XCTAssertThrowsError(try gate.reserve(alias, now: now))
        try gate.reserve(URL(string: "https://example.invalid/subscription?token=different")!, now: now)
    }

    func testConcurrentGateInstancesAdmitOnlyOneRequest() async {
        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<20 {
                group.addTask { [self] in do { try gate.reserve(url, now: now); return true } catch { return false } }
            }
            var results: [Bool] = []
            for await value in group { results.append(value) }
            return results
        }
        XCTAssertEqual(outcomes.filter { $0 }.count, 1)
    }

    func testCorruptOrUnwritableRecordFailsClosedAndClockRollbackDoesNotUnlock() throws {
        try gate.reserve(url, now: now)
        XCTAssertThrowsError(try gate.reserve(url, now: now.addingTimeInterval(-86400)))
        try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try gate.reserve(url, now: now.addingTimeInterval(100 * 3600)))
        XCTAssertEqual(try String(contentsOf: file), "broken")
        let blocked = SubscriptionRequestGate(storeURL: file.appendingPathComponent("child.json"))
        XCTAssertThrowsError(try blocked.reserve(url, now: now))
    }
}
