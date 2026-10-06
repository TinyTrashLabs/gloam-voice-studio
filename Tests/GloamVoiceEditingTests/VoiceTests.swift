import XCTest
import GVoiceKit
@testable import GloamVoiceEditing

final class VoiceTests: XCTestCase {
    private func voice(name: String, notes: String? = nil, starter: Bool = false) -> Voice {
        Voice(slug: "x", meta: VoiceMeta(name: name, slug: "x", refText: "", createdAt: "", notes: notes),
              hasMaster: true, hasWindow: false, variantKeys: [], isStarter: starter,
              avatarURL: nil, avatarModified: nil)
    }

    func testTagIsInitialsOfFirstTwoWords() {
        XCTAssertEqual(Voice.tag(for: "Billie Frost"), "BF")
        XCTAssertEqual(Voice.tag(for: "Jeff"), "JE")
        XCTAssertEqual(Voice.tag(for: "Sonny Vale Late"), "SV")
    }

    func testBlurbPrefersNotes() {
        XCTAssertEqual(voice(name: "A", notes: "gravelly").blurb, "gravelly")
        XCTAssertEqual(voice(name: "A", starter: true).blurb, "Included voice")
        XCTAssertEqual(voice(name: "A").blurb, "Added")
    }

    func testClonedBlurbCarriesTheDay() {
        let v = Voice(slug: "x", meta: VoiceMeta(name: "Me", slug: "x", refText: "", createdAt: "2026-09-08T13:17:00Z"),
                      hasMaster: true, hasWindow: false, variantKeys: [], isStarter: false,
                      avatarURL: nil, avatarModified: nil)
        XCTAssertTrue(v.blurb.hasPrefix("Added "), v.blurb)
        XCTAssertNotNil(Voice.day(from: "2026-09-08T13:17:00Z"))
        XCTAssertNotNil(Voice.day(from: "2026-09-08T13:17:00.123Z"))
        XCTAssertNil(Voice.day(from: "yesterday"))
        XCTAssertEqual(voice(name: "S", starter: true).blurb, "Included voice")
    }
}
