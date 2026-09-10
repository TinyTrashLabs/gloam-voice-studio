import XCTest
@testable import EngineKit

/// Dia2 gives the first turn of a pass to speaker 1 whatever the script says,
/// so a pass opening on `[S2]` used to come back with both voices on each
/// other's lines. These lock the rebinding that prevents it.
final class DialogueSpeakerBindingTests: XCTestCase {
    private func clip(_ word: String) -> DialoguePrefix {
        DialoguePrefix(samples: [0.1, 0.2],
                       words: [AlignedWordTiming(text: word, start: 0, end: 1)])
    }
    private var benson: DialoguePrefix { clip("benson") }
    private var midge: DialoguePrefix { clip("midge") }

    /// The content words of a script, tags dropped — what the model reports
    /// back as its transcript, in order.
    private func words(_ script: [String]) -> [String] {
        script.flatMap { $0.split(separator: " ").map(String.init) }
            .filter { $0 != "[S1]" && $0 != "[S2]" }
    }

    // MARK: - The pass that opens on speaker 1 is already correct

    func testAPassOpeningOnSpeakerOneIsLeftAlone() {
        let script = ["[S1] first line", "[S2] second line"]
        let binding = DialogueSpeakerBinding(script: script, prefixes: [benson, midge])
        XCTAssertFalse(binding.swapped)
        XCTAssertEqual(binding.script, script)
        XCTAssertEqual(binding.prefixes[0], benson)
        XCTAssertEqual(binding.prefixes[1], midge)
    }

    func testAnUntaggedScriptOpensOnSpeakerOne() {
        let binding = DialogueSpeakerBinding(script: ["no tag here"],
                                             prefixes: [benson, midge])
        XCTAssertFalse(binding.swapped)
    }

    // MARK: - The pass that opens on speaker 2 is rebound

    /// The opener's INTENDED speaker must get the opener's voice. Dia2 hands
    /// the first turn to whatever is in prefix slot 1, so slot 1 has to hold
    /// the clip of the speaker who actually opens.
    func testAPassOpeningOnSpeakerTwoPutsThatSpeakersClipFirst() {
        let script = ["[S2] midge opens", "[S1] benson answers"]
        let binding = DialogueSpeakerBinding(script: script, prefixes: [benson, midge])

        XCTAssertTrue(binding.swapped)
        // Slot 1 is the voice Dia2 will give the opening turn to.
        XCTAssertEqual(binding.prefixes[0], midge, "the opener must get the opener's voice")
        XCTAssertEqual(binding.prefixes[1], benson)
        // ...and the tags move with it, so the clip in slot 1 is the one the
        // script's `[S1]` now names.
        XCTAssertEqual(binding.script, ["[S1] midge opens", "[S2] benson answers"])
    }

    /// The bug this replaces: tags flipped without the clips following, or the
    /// clips left in place, both leave the opener in the wrong voice.
    func testTagsAndClipsMoveTogetherOrNotAtAll() {
        for script in [["[S2] a", "[S1] b"], ["[S1] a", "[S2] b"]] {
            let binding = DialogueSpeakerBinding(script: script, prefixes: [benson, midge])
            let flipped = binding.script != script
            let exchanged = binding.prefixes[0] != benson
            XCTAssertEqual(flipped, exchanged,
                           "tags and clips must move together for \(script)")
        }
    }

    func testEveryTagFlipsNotJustTheOpeningOne() {
        let binding = DialogueSpeakerBinding(
            script: ["[S2] one", "[S1] two", "[S2] three [S1] mid-line"],
            prefixes: [benson, midge])
        XCTAssertEqual(binding.script,
                       ["[S1] one", "[S2] two", "[S1] three [S2] mid-line"])
    }

    func testFlippingTwiceIsTheIdentity() {
        let line = "[S2] a [S1] b [S2] c"
        XCTAssertEqual(
            DialogueSpeakerBinding.flippingTags(DialogueSpeakerBinding.flippingTags(line)),
            line)
    }

    // MARK: - The transcript still belongs to the ORIGINAL script

    /// Callers attribute the returned words positionally against their own,
    /// unflipped script. That only stays correct because rebinding changes
    /// tags and nothing else: same words, same order, same count. If a flip
    /// ever added or moved a word, every speaker-slice and tail-trim
    /// downstream would silently shift.
    func testRebindingDoesNotDisturbTheTranscript() {
        let script = ["[S2] McIndoe has gone through periods",
                      "[S1] He has also discussed the concept",
                      "[S2] He frames his later appearances"]
        let binding = DialogueSpeakerBinding(script: script, prefixes: [benson, midge])
        XCTAssertTrue(binding.swapped)
        XCTAssertEqual(words(binding.script), words(script),
                       "the model must report the same transcript either way")
    }

    /// The caller's own script is never mutated, so the speaker labels it
    /// hands downstream remain the original ones rather than the internal
    /// flipped ones.
    func testTheCallersScriptIsNotMutated() {
        let script = ["[S2] mine", "[S1] yours"]
        _ = DialogueSpeakerBinding(script: script, prefixes: [benson, midge])
        XCTAssertEqual(script, ["[S2] mine", "[S1] yours"])
    }

    // MARK: - Cases the swap must refuse

    /// Dia2 cannot condition speaker 2 alone, so exchanging a lone speaker-1
    /// clip into the second slot would make the pass throw. Sounding wrong
    /// beats failing to render.
    func testALoneClipIsNotExchanged() {
        let binding = DialogueSpeakerBinding(script: ["[S2] opens"], prefixes: [benson, nil])
        XCTAssertFalse(binding.swapped)
        XCTAssertEqual(binding.prefixes[0], benson)
        XCTAssertEqual(binding.script, ["[S2] opens"])
    }

    func testNoClipsAtAllStillRebindsTheTags() {
        let binding = DialogueSpeakerBinding(script: ["[S2] opens", "[S1] answers"],
                                             prefixes: [nil, nil])
        XCTAssertTrue(binding.swapped)
        XCTAssertEqual(binding.script, ["[S1] opens", "[S2] answers"])
    }

    /// An empty or short prefix array must not trap on the exchange.
    func testShortPrefixArraysAreSafe() {
        XCTAssertEqual(DialogueSpeakerBinding(script: ["[S2] a"], prefixes: []).script,
                       ["[S1] a"])
        XCTAssertEqual(DialogueSpeakerBinding(script: [], prefixes: []).script, [])
        XCTAssertFalse(DialogueSpeakerBinding(script: ["[S2] a"], prefixes: [nil]).prefixes.isEmpty)
    }

    /// `DialoguePlanner.script` renders "[S2] text"; a colon-separated variant
    /// reaches the parser the same way, so the opener test must see it too.
    func testAColonAfterTheTagStillReadsAsTheOpener() {
        XCTAssertTrue(DialogueSpeakerBinding.opensOnSpeakerTwo(["[S2]: opens"]))
        XCTAssertFalse(DialogueSpeakerBinding.opensOnSpeakerTwo(["[S1]: opens"]))
    }
}
