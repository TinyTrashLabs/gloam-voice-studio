import XCTest
@testable import StudioKit

final class ExpandableTextHeightTests: XCTestCase {
    func testForLineCountClampsToMinForShortText() {
        XCTAssertEqual(ExpandableTextHeight.forLineCount(1, min: 44, max: 220), 44)
    }

    func testForLineCountClampsToMaxForLongText() {
        XCTAssertEqual(ExpandableTextHeight.forLineCount(20, min: 44, max: 220), 220)
    }

    func testForLineCountGrowsLinearlyWithinRange() {
        XCTAssertEqual(ExpandableTextHeight.forLineCount(5, min: 44, max: 220), 106)
    }

    func testDraggedAddsDeltaToBase() {
        XCTAssertEqual(ExpandableTextHeight.dragged(base: 100, delta: 50, min: 44, max: 600), 150)
    }

    func testDraggedClampsToMin() {
        XCTAssertEqual(ExpandableTextHeight.dragged(base: 100, delta: -80, min: 44, max: 600), 44)
    }

    func testDraggedClampsToMax() {
        XCTAssertEqual(ExpandableTextHeight.dragged(base: 100, delta: 1000, min: 44, max: 600), 600)
    }
}
