import XCTest
@testable import StudioKit

final class SlugTests: XCTestCase {
    func testLowercasesAndDashes() throws {
        XCTAssertEqual(try Slug.slugify("Cruz Vibes!"), "cruz-vibes")
    }
    func testCollapsesRunsAndStripsEnds() throws {
        XCTAssertEqual(try Slug.slugify("--Hype__2--"), "hype-2")
    }
    func testNonASCIIBecomesDash() throws {
        XCTAssertEqual(try Slug.slugify("héllo"), "h-llo")  // matches Python [^a-z0-9]+
    }
    func testEmptySlugThrows() {
        XCTAssertThrowsError(try Slug.slugify("!!!")) { error in
            XCTAssertEqual(error as? StudioError, .invalidName("!!!"))
        }
    }
}
