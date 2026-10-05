import XCTest
import GVoiceKit
@testable import GloamVoiceEditing

final class VoiceFilterTests: XCTestCase {
    private func voice(_ name: String, notes: String? = nil, starter: Bool = false) -> Voice {
        Voice(slug: (try? Slug.slugify(name)) ?? name, meta: VoiceMeta(name: name, slug: "", refText: "", createdAt: "", notes: notes),
              hasMaster: true, hasWindow: false, variantKeys: [], isStarter: starter,
              avatarURL: nil, avatarModified: nil)
    }

    func testEmptyQueryKeepsAll() {
        let voices = [voice("Jeff"), voice("Cruz"), voice("Billie Frost")]
        XCTAssertEqual(VoiceFilter.apply(voices, query: "").count, 3)
        XCTAssertEqual(VoiceFilter.apply(voices, query: "   ").count, 3)
    }

    func testMatchesOnName() {
        let v = voice("Billie Frost")
        XCTAssertTrue(VoiceFilter.matches(v, query: "billie"))
    }

    func testMatchesOnTag() {
        // tag is initials of the name, e.g. "Billie Frost" -> "BF"
        let v = voice("Billie Frost")
        XCTAssertTrue(VoiceFilter.matches(v, query: "BF"))
    }

    func testMatchesOnBlurb() {
        let v = voice("Cruz", notes: "warm late-night host")
        XCTAssertTrue(VoiceFilter.matches(v, query: "late-night"))
    }

    func testCaseAndDiacriticInsensitive() {
        let v = voice("José")
        XCTAssertTrue(VoiceFilter.matches(v, query: "jose"))
        XCTAssertTrue(VoiceFilter.matches(v, query: "JOSE"))
    }

    func testNoMatchReturnsEmpty() {
        let voices = [voice("Jeff"), voice("Cruz")]
        XCTAssertEqual(VoiceFilter.apply(voices, query: "zzz-nonexistent"), [])
    }

    func testClonesBeforeStartersStableWithinGroup() {
        let starterA = voice("Billie Frost", starter: true)
        let starterB = voice("Jeff", starter: true)
        let cloneA = voice("My Voice")
        let cloneB = voice("Second Take")
        let voices = [starterA, cloneA, starterB, cloneB]
        let result = VoiceFilter.apply(voices, query: "")
        XCTAssertEqual(result.map(\.name), ["My Voice", "Second Take", "Billie Frost", "Jeff"])
    }
}
