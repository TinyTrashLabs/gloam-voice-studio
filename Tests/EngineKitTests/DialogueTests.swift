import XCTest
@testable import EngineKit

final class DialogueTests: XCTestCase {
    private func lines(_ slugs: [String?]) -> [DialogueLine] {
        slugs.enumerated().map {
            DialogueLine(index: $0.offset, voiceSlug: $0.element, text: "a line")
        }
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

    /// Every control has to survive the trip from the caller's request to the
    /// provider's. They were declared on both sides and connected on neither,
    /// which is indistinguishable from the model ignoring them.
    func testEveryControlReachesTheProviderRequest() {
        let dialogue = DialogueRequest(
            turns: [DialogueTurn(speaker: 1, text: "Hello")],
            voices: ["ava"],
            temperature: 0.7, topK: 42, cfgScale: 6,
            textTemperature: 0.45, textTopK: 31,
            audioTemperature: 0.85, audioTopK: 67,
            maxPadding: 5, keepPrefixAudio: true)

        let provider = ProviderDialogueRequest(dialogue, script: ["[S1] Hello"], prefixes: [nil])

        XCTAssertEqual(provider.script, ["[S1] Hello"])
        XCTAssertEqual(provider.temperature, 0.7)
        XCTAssertEqual(provider.topK, 42)
        XCTAssertEqual(provider.cfgScale, 6)
        XCTAssertEqual(provider.textTemperature, 0.45)
        XCTAssertEqual(provider.textTopK, 31)
        XCTAssertEqual(provider.audioTemperature, 0.85)
        XCTAssertEqual(provider.audioTopK, 67)
        XCTAssertEqual(provider.maxPadding, 5)
        XCTAssertTrue(provider.keepPrefixAudio)
    }

    /// A request that sets nothing must not invent settings — the model's own
    /// defaults are better than any this layer could guess.
    func testUnsetControlsStayUnset() {
        let provider = ProviderDialogueRequest(
            DialogueRequest(turns: [], voices: []), script: [], prefixes: [])
        XCTAssertNil(provider.textTemperature)
        XCTAssertNil(provider.audioTopK)
        XCTAssertNil(provider.maxPadding)
        XCTAssertFalse(provider.keepPrefixAudio)
    }

    func testEmptyScriptIsRejected() {
        let request = DialogueRequest(turns: [], voices: [])
        XCTAssertThrowsError(try DialoguePlanner.script(for: request, knownTags: []))
    }

    /// The download manager resolves the folder with quant "8bit" and the
    /// loader resolves it with nil. If those disagree the UI reports a model
    /// ready that the loader cannot find, and the load falls through to a
    /// remote fetch that 401s.
    func testDia2DiskFolderIsTheSameForBothResolvers() {
        // Both the download manager and AppModel's loader resolver pass nil for
        // anything that isn't Qwen, so both must land on the size-qualified
        // default. Feeding dia2 a bare Qwen quant is the bug this guards.
        let downloadManagerStyle = BackendID.dia2.isQwen ? "8bit" : nil
        let loaderStyle: String? = BackendID.dia2.isQwen ? "8bit" : nil
        XCTAssertEqual(BackendID.dia2.diskFolder(quantRaw: downloadManagerStyle),
                       BackendID.dia2.diskFolder(quantRaw: loaderStyle))
        XCTAssertEqual(BackendID.dia2.diskFolder(quantRaw: loaderStyle), "dia2@2b-8bit")
        XCTAssertNotEqual(BackendID.dia2.diskFolder(quantRaw: nil),
                          BackendID.dia2.diskFolder(quantRaw: "8bit"),
                          "a bare Qwen quant must not silently name a real folder")
    }

    /// Dia2 has separate text/action and audio samplers. Collapsing them back
    /// into one temperature/top-k pair would make the parity controls lie.
    func testProviderControlsMapToIndependentDia2Samplers() {
        let request = ProviderDialogueRequest(
            script: ["[S1] Hello"], prefixes: [],
            cfgScale: 6.5,
            textTemperature: 0.45, textTopK: 31,
            audioTemperature: 0.85, audioTopK: 67,
            maxPadding: 5, keepPrefixAudio: true)

        let config = Dia2RequestAdapter.config(request)

        XCTAssertEqual(config.textTemperature, 0.45)
        XCTAssertEqual(config.textTopK, 31)
        XCTAssertEqual(config.audioTemperature, 0.85)
        XCTAssertEqual(config.audioTopK, 67)
        XCTAssertEqual(config.cfgScale, 6.5)
        XCTAssertEqual(config.maxPadding, 5)
    }

    /// "Keep prefix" means actual prefix PCM and correctly shifted timings,
    /// not the delayed tail leak that originally appeared before generation.
    func testKeepingPrefixesPrependsBothVoicesAndShiftsGeneratedWords() {
        let prefixes = [
            DialoguePrefix(samples: [0.1, 0.2],
                           words: [AlignedWordTiming(text: "one", start: 0, end: 0.5)]),
            DialoguePrefix(samples: [0.3],
                           words: [AlignedWordTiming(text: "two", start: 0, end: 0.25)]),
        ]
        let result = DialogueOutputAssembler.assemble(
            generated: DialogueChunk(
                samples: [0.9],
                words: [AlignedWordTiming(text: "hello", start: 0.1, end: 0.2)]),
            prefixes: prefixes, sampleRate: 2, keepPrefixAudio: true)

        XCTAssertEqual(result.samples, [0.1, 0.2, 0.3, 0.9])
        XCTAssertEqual(result.words, [
            AlignedWordTiming(text: "one", start: 0, end: 0.5),
            AlignedWordTiming(text: "two", start: 1, end: 1.25),
            AlignedWordTiming(text: "hello", start: 1.6, end: 1.7),
        ])
    }

    func testDiscardingPrefixesLeavesGeneratedOutputUntouched() {
        let generated = DialogueChunk(
            samples: [0.9],
            words: [AlignedWordTiming(text: "hello", start: 0.1, end: 0.2)])
        let result = DialogueOutputAssembler.assemble(
            generated: generated,
            prefixes: [DialoguePrefix(samples: [0.1], words: [])],
            sampleRate: 2, keepPrefixAudio: false)

        XCTAssertEqual(result.samples, generated.samples)
        XCTAssertEqual(result.words, generated.words)
    }
}
