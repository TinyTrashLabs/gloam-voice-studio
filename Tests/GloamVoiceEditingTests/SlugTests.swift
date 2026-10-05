import XCTest
@testable import GloamVoiceEditing

/// Copied from StudioKit's `Slug` (gloam-voice-studio) so both apps mint the
/// same slug for the same name. Keep the cases in sync with SlugTests there.
final class SlugTests: XCTestCase {
    func testLowercasesAndDashes() throws {
        XCTAssertEqual(try Slug.slugify("Billie Frost"), "billie-frost")
    }

    func testCollapsesRunsAndTrimsEdges() throws {
        XCTAssertEqual(try Slug.slugify("  DJ -- Nova!! "), "dj-nova")
    }

    func testEmptyResultThrows() {
        XCTAssertThrowsError(try Slug.slugify("!!!"))
    }
}
