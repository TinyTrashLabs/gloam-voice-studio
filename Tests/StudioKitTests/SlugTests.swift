import XCTest
@testable import StudioKit

final class SlugTests: XCTestCase {
    func testStudioErrorEquatable() {
        XCTAssertEqual(StudioError.voiceExists(slug: "a"), .voiceExists(slug: "a"))
    }
}
