import XCTest
@testable import StudioKit

/// Which field a click-to-insert tag chip writes into, when the writing surface
/// is a list of fields rather than one box.
///
/// Clicking a chip is a click somewhere OTHER than the text, so "the focused
/// field" is often already "the field that was focused a moment ago". Getting
/// this wrong doesn't fail loudly — it drops `(laughs)` into the wrong line of
/// somebody's script — so the resolution is a function with tests rather than
/// a guess inside a view.
final class TagInsertionTargetTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    func testTheFocusedFieldWins() {
        XCTAssertEqual(TagInsertionTarget.resolve(focused: a, lastFocused: b, existing: [a, b]), a)
    }

    /// The ordinary case at the moment a chip is clicked.
    func testTheLastFocusedFieldIsUsedWhenNothingIsFocused() {
        XCTAssertEqual(TagInsertionTarget.resolve(focused: nil, lastFocused: b, existing: [a, b]), b)
    }

    /// The outcome worth writing a test for: the remembered turn was deleted.
    /// Resolving to a neighbour would insert into a line the user never chose,
    /// so this resolves to nothing and the chips go quiet instead.
    func testADeletedFieldResolvesToNothingRatherThanANeighbour() {
        XCTAssertNil(TagInsertionTarget.resolve(focused: nil, lastFocused: c, existing: [a, b]))
    }

    func testAFocusedFieldThatIsGoneResolvesToNothing() {
        XCTAssertNil(TagInsertionTarget.resolve(focused: c, lastFocused: nil, existing: [a, b]))
    }

    func testNoFieldsMeansNoTarget() {
        XCTAssertNil(TagInsertionTarget.resolve(focused: a, lastFocused: b, existing: []))
    }

    func testNothingRememberedMeansNoTarget() {
        XCTAssertNil(TagInsertionTarget.resolve(focused: nil, lastFocused: nil, existing: [a, b]))
    }
}
