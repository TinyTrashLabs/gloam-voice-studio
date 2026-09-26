import XCTest
@testable import StudioKit

final class LabExpansionTests: XCTestCase {
    func testEverythingStartsCollapsed() {
        let e = LabExpansion()
        XCTAssertTrue(e.isCollapsed("a"))
        XCTAssertTrue(e.isCollapsed("never-seen"))
    }

    func testToggleOpensThenCloses() {
        var e = LabExpansion()
        e.toggle("a")
        XCTAssertFalse(e.isCollapsed("a"))
        XCTAssertTrue(e.isCollapsed("b"), "toggling one group leaves the others alone")
        e.toggle("a")
        XCTAssertTrue(e.isCollapsed("a"))
    }

    func testCollapseAllAndExpandAll() {
        var e = LabExpansion()
        e.expandAll(["a", "b", "c"])
        XCTAssertFalse(e.isCollapsed("b"))
        e.collapseAll()
        XCTAssertTrue(["a", "b", "c"].allSatisfy(e.isCollapsed))
    }

    /// A comparison the user just created is the one they are about to edit.
    func testExpandOpensOneGroup() {
        var e = LabExpansion()
        e.expand("new")
        XCTAssertFalse(e.isCollapsed("new"))
        XCTAssertTrue(e.isCollapsed("old"))
    }
}
