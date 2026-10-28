import XCTest
@testable import TrafficCore

final class CoreTests: XCTestCase {
    func testHeaderUnitsExpiryAndOverflow() throws {
        let info = try Subscription.parse(" download=3000000000; Upload=1000000000; total=10000000000; expire=1893456000 ")
        XCTAssertEqual(info.remaining, 6_000_000_000)
        XCTAssertEqual(info.used, 4_000_000_000)
        XCTAssertEqual(info.expiry?.timeIntervalSince1970, 1893456000)
        XCTAssertEqual(TrafficFormat.gb(info.used), "4.00 GB")
        for header in ["upload=1;total=10", "upload=-1;download=0;total=1", "upload=1.5;download=0;total=1",
                       "upload=1;download=0;total=1;total=2", "upload=18446744073709551615;download=1;total=1",
                       "upload=1;download=0;total=1;expire=999999999999999"] {
            XCTAssertThrowsError(try Subscription.parse(header))
        }
    }
    func testUnlimitedAndOverage() throws {
        XCTAssertNil(try Subscription.parse("upload=1;download=9;total=0;expire=0").remaining)
        XCTAssertNil(try Subscription.parse("upload=1;download=9;total=0;expire=0").expiry)
        XCTAssertEqual(try Subscription.parse("upload=1;download=9;total=5").remaining, 0)
    }
    func testURLValidation() throws {
        for url in ["http://example.invalid/token", "file:///tmp/file", "https:///", "https://user:pass@example.invalid/sub", "https://example.invalid/sub#fragment"] {
            XCTAssertThrowsError(try Subscription.validatedURL(url))
        }
        XCTAssertEqual(try Subscription.validatedURL(" https://example.invalid/sub?token=fixture ").host, "example.invalid")
    }
    func testResetDoesNotInventUsage() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var ledger = Ledger()
        func info(_ up: UInt64, _ down: UInt64) throws -> Subscription { try Subscription(upload: up, download: down, total: 1000) }
        try ledger.append(info(10, 100), at: start)
        try ledger.append(info(20, 150), at: start.addingTimeInterval(60))
        XCTAssertTrue(try ledger.append(info(0, 20), at: start.addingTimeInterval(120)))
        try ledger.append(info(1, 40), at: start.addingTimeInterval(180))
        let usage = ledger.usage(in: DateInterval(start: start, duration: 240))
        XCTAssertEqual(usage.bytes, 81)
        XCTAssertEqual(usage.intervals, 2)
        XCTAssertEqual(usage.excludedIntervals, 1)
        try ledger.validate()
        XCTAssertThrowsError(try ledger.append(info(2, 41), at: start))
    }
    func testCrossBoundaryAndPlanChanges() throws {
        var ledger = Ledger()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try ledger.append(Subscription(upload: 0, download: 100, total: 1000), at: start.addingTimeInterval(-30))
        try ledger.append(Subscription(upload: 0, download: 150, total: 1000), at: start.addingTimeInterval(30))
        XCTAssertFalse(try ledger.append(Subscription(upload: 0, download: 200, total: 2000,
                                                     expiry: start.addingTimeInterval(86400)), at: start.addingTimeInterval(60)))
        let usage = ledger.usage(in: DateInterval(start: start, duration: 86400))
        // A changed quota is an unverified counter boundary, not observed usage.
        XCTAssertEqual(usage.bytes, 0)
        XCTAssertEqual(usage.excludedIntervals, 2)
        try ledger.append(Subscription(upload: 0, download: 225, total: 2000,
                                       expiry: start.addingTimeInterval(86400)), at: start.addingTimeInterval(90))
        XCTAssertEqual(ledger.usage(in: DateInterval(start: start, duration: 86400)).bytes, 25)
    }
    func testFirstBaselineIsNotDailyUsage() throws {
        var ledger = Ledger()
        let now = Date()
        try ledger.append(Subscription(upload: 100, download: 9999, total: 100_000), at: now)
        XCTAssertEqual(ledger.usage(in: DateInterval(start: now.addingTimeInterval(-10), duration: 20)).intervals, 0)
    }
    func testIndividualCounterRollbackEvenWhenSumIncreases() throws {
        var ledger = Ledger()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try ledger.append(Subscription(upload: 100, download: 200, total: 1000), at: start)
        ledger.lowBalanceNotified = true
        XCTAssertTrue(try ledger.append(Subscription(upload: 0, download: 400, total: 1000), at: start.addingTimeInterval(60)))
        XCTAssertFalse(ledger.lowBalanceNotified)
        XCTAssertEqual(ledger.usage(in: DateInterval(start: start, duration: 120)).bytes, 0)
    }
    func testISOWeekAndLocalMidnightBoundaries() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 23, minute: 55))!
        let monday = sunday.addingTimeInterval(600)
        var ledger = Ledger()
        try ledger.append(Subscription(upload: 0, download: 100, total: 1000), at: sunday)
        try ledger.append(Subscription(upload: 0, download: 150, total: 1000), at: monday)
        try ledger.append(Subscription(upload: 0, download: 170, total: 1000), at: monday.addingTimeInterval(60))
        let day = calendar.dateInterval(of: .day, for: monday)!
        let week = calendar.dateInterval(of: .weekOfYear, for: monday)!
        XCTAssertEqual(calendar.component(.weekday, from: week.start), 2)
        XCTAssertEqual(ledger.usage(in: day).bytes, 20)
        XCTAssertEqual(ledger.usage(in: week).bytes, 20)
        XCTAssertEqual(ledger.usage(in: week).excludedIntervals, 1)
    }
    func testAtomicPersistenceAndCorruptionProtection() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(url: folder.appendingPathComponent("history.json"))
        XCTAssertTrue(try store.load().samples.isEmpty)
        var ledger = Ledger()
        try ledger.append(Subscription(upload: 1, download: 2, total: 10))
        try store.save(ledger)
        XCTAssertEqual(try store.load().samples.last?.subscription.used, 3)
        try Data("broken".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try String(contentsOf: store.url), "broken")
        try store.quarantine()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
    }
}
