import XCTest
@testable import EngineKit

final class DialogueTests: XCTestCase {
    private func lines(_ slugs: [String?]) -> [(index: Int, voiceSlug: String?)] {
        slugs.enumerated().map { ($0.offset, $0.element) }
    }

    /// Two voices in a row is one scene — that is the whole point.
    func testTwoVoicesFormOneScene() {
        let scenes = DialoguePlanner.scenes(for: lines(["ava", "ben", "ava", "ben"]))
        XCTAssertEqual(scenes.count, 1)
        XCTAssertEqual(scenes[0].lines, [0, 1, 2, 3])
        XCTAssertEqual(Set(scenes[0].voices), ["ava", "ben"])
    }

    /// A third voice starts a new scene rather than being silently dropped.
    func testThirdVoiceStartsANewScene() {
        let scenes = DialoguePlanner.scenes(for: lines(["ava", "ben", "cass", "ava"]))
        XCTAssertEqual(scenes.count, 2)
        XCTAssertEqual(scenes[0].lines, [0, 1])
        XCTAssertEqual(scenes[1].lines, [2, 3])
    }

    func testASingleVoiceIsStillAValidScene() {
        let scenes = DialoguePlanner.scenes(for: lines(["ava", "ava"]))
        XCTAssertEqual(scenes.count, 1)
        XCTAssertEqual(scenes[0].voices, ["ava"])
    }

    /// An unassigned line joins the current scene without claiming a slot.
    func testUnassignedLinesJoinTheCurrentScene() {
        let scenes = DialoguePlanner.scenes(for: lines(["ava", nil, "ben"]))
        XCTAssertEqual(scenes.count, 1)
        XCTAssertEqual(scenes[0].lines, [0, 1, 2])
    }

    func testScriptRendersSpeakerTags() throws {
        let request = DialogueRequest(
            turns: [DialogueTurn(speaker: 1, text: "Hello"),
                    DialogueTurn(speaker: 2, text: "Hi there")],
            voices: ["ava", "ben"])
        let script = try DialoguePlanner.script(for: request, knownTags: [])
        XCTAssertEqual(script, ["[S1] Hello", "[S2] Hi there"])
    }

    func testThirdSpeakerInARequestIsRejected() {
        let request = DialogueRequest(
            turns: [DialogueTurn(speaker: 3, text: "nope")], voices: ["ava"])
        XCTAssertThrowsError(try DialoguePlanner.script(for: request, knownTags: [])) { error in
            guard case DialogueError.tooManySpeakers = error else {
                return XCTFail("expected tooManySpeakers, got \(error)")
            }
        }
    }

    /// A tag the checkpoint never learned would be spoken aloud as text.
    func testUnknownNonverbalTagIsRejected() {
        let request = DialogueRequest(
            turns: [DialogueTurn(speaker: 1, text: "well (yodels) ok")], voices: [])
        XCTAssertThrowsError(
            try DialoguePlanner.script(for: request, knownTags: ["(laughs)"])) { error in
            guard case DialogueError.unknownTag(let tag) = error else {
                return XCTFail("expected unknownTag, got \(error)")
            }
            XCTAssertEqual(tag, "(yodels)")
        }
    }

    func testKnownTagPassesThrough() throws {
        let request = DialogueRequest(
            turns: [DialogueTurn(speaker: 1, text: "well (laughs) ok")], voices: [])
        let script = try DialoguePlanner.script(for: request, knownTags: ["(laughs)"])
        XCTAssertEqual(script, ["[S1] well (laughs) ok"])
    }

    func testEmptyScriptIsRejected() {
        let request = DialogueRequest(turns: [], voices: [])
        XCTAssertThrowsError(try DialoguePlanner.script(for: request, knownTags: []))
    }
}
