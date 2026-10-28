import XCTest
@testable import TrafficCore

final class DisplayTests: XCTestCase {
    func testMenuValuesUseCompactExplicitUnits() {
        XCTAssertEqual(TrafficUnit.gb.menuText(212_760_000_000), "212.8 GB")
        XCTAssertEqual(TrafficUnit.gb.menuText(512_000_000), "512 MB")
        XCTAssertEqual(TrafficUnit.gb.menuText(512_000), "512 KB")
        XCTAssertEqual(TrafficUnit.gb.menuText(0), "0 GB")
        XCTAssertEqual(TrafficUnit.gb.menuText(1_500_000_000_000), "1.5 TB")
    }
    func testBinaryAndDecimalStayDistinct() {
        XCTAssertEqual(TrafficUnit.gib.text(214_748_364_800), "200.00 GiB")
        XCTAssertEqual(TrafficUnit.gb.text(214_748_364_800), "214.75 GB")
        XCTAssertEqual(TrafficUnit.gib.menuText(536_870_912), "512 MiB")
        XCTAssertEqual(TrafficUnit.gib.menuText(1_073_741_824), "1.0 GiB")
    }
}
