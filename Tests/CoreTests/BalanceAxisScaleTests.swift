import XCTest
@testable import TrafficCore

final class BalanceAxisScaleTests: XCTestCase {
    func testIntegerLabelsMatchTheActualPlottedBounds() {
        let axis = BalanceAxisScale(lowerBytes: 188.2e9, upperBytes: 215.4e9, unit: .gb)
        XCTAssertEqual(axis.lowerLabel, "188")
        XCTAssertEqual(axis.upperLabel, "216")
        XCTAssertEqual(axis.lowerBytes, 188e9, accuracy: 1)
        XCTAssertEqual(axis.upperBytes, 216e9, accuracy: 1)
    }

    func testBinaryUnitAndNarrowRangesRetainTheirScale() {
        let unit = TrafficUnit.gib
        let axis = BalanceAxisScale(lowerBytes: 1.234 * unit.divisor,
                                    upperBytes: 1.256 * unit.divisor, unit: unit)
        XCTAssertEqual(axis.lowerLabel, "1.234")
        XCTAssertEqual(axis.upperLabel, "1.256")
        XCTAssertLessThanOrEqual(axis.lowerBytes, 1.234 * unit.divisor)
        XCTAssertGreaterThanOrEqual(axis.upperBytes, 1.256 * unit.divisor)
    }

    func testZeroAndSubMegabyteBalancesNeverCollapseToIdenticalLabels() {
        for (low, high) in [(0.0, 0.0), (10.0, 20.0), (0.0, 500_000.0)] {
            let axis = BalanceAxisScale(lowerBytes: low, upperBytes: high, unit: .gb)
            XCTAssertGreaterThan(axis.upperBytes, axis.lowerBytes)
            XCTAssertGreaterThanOrEqual(axis.lowerBytes, 0)
            XCTAssertNotEqual(axis.lowerLabel, axis.upperLabel)
            XCTAssertLessThanOrEqual(axis.upperLabel.count, 9)
        }
    }

    func testScientificNotationStillMatchesThePlotBounds() throws {
        for (low, high) in [(0.0001234, 0.0001256), (188_200.0, 215_400.0)] {
            let axis = BalanceAxisScale(lowerBytes: low * TrafficUnit.gb.divisor,
                                        upperBytes: high * TrafficUnit.gb.divisor, unit: .gb)
            XCTAssertEqual(try XCTUnwrap(Double(axis.lowerLabel)) * TrafficUnit.gb.divisor,
                           axis.lowerBytes, accuracy: max(0.0001, axis.lowerBytes * 1e-12))
            XCTAssertEqual(try XCTUnwrap(Double(axis.upperLabel)) * TrafficUnit.gb.divisor,
                           axis.upperBytes, accuracy: max(0.0001, axis.upperBytes * 1e-12))
        }
    }
}
