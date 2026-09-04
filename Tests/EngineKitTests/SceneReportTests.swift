import XCTest
@testable import EngineKit

final class SceneReportTests: XCTestCase {
    private func named(_ slugs: [String]) -> [DialogueLine] {
        slugs.enumerated().map {
            DialogueLine(index: $0.offset, voiceSlug: $0.element, text: "a line")
        }
    }

    func testReportNamesTheSplitPoints() {
        let report = DialoguePlanner.report(for: named(["ava", "ben", "cass", "ava", "dee"]))
        XCTAssertEqual(report.sceneCount, 3)
        XCTAssertEqual(report.splitAfterLines, [1, 3])
    }

    func testASingleSceneReportsNoSplits() {
        let report = DialoguePlanner.report(for: named(["ava", "ben"]))
        XCTAssertEqual(report.sceneCount, 1)
        XCTAssertTrue(report.splitAfterLines.isEmpty)
    }

    func testAnEmptyScriptReportsNoScenes() {
        let report = DialoguePlanner.report(for: [])
        XCTAssertEqual(report.sceneCount, 0)
        XCTAssertTrue(report.splitAfterLines.isEmpty)
    }
}

/// The duration budget. Dia2 has three ceilings and only the first is the
/// context window, so these tests pin the behaviour to the one that actually
/// governs quality — see `DialoguePlanner.sceneBudgetSeconds`.
final class DialogueBudgetTests: XCTestCase {
    /// ~2.7 words/second, so 27 words is about ten seconds of speech.
    private func line(_ index: Int, _ voice: String, words: Int) -> DialogueLine {
        DialogueLine(index: index, voiceSlug: voice,
                     text: Array(repeating: "word", count: words).joined(separator: " "))
    }

    func testWordCountEstimatesDuration() {
        XCTAssertEqual(DialoguePlanner.estimatedSeconds(of: "one two three"),
                       3 / 2.7, accuracy: 0.001)
        XCTAssertEqual(DialoguePlanner.estimatedSeconds(of: "   "), 0)
    }

    /// A short exchange is one pass; the budget must not split what fits.
    func testAShortExchangeStaysOnePass() {
        let lines = (0..<4).map { line($0, $0.isMultiple(of: 2) ? "ava" : "ben", words: 10) }
        let scenes = DialoguePlanner.scenes(for: lines)
        XCTAssertEqual(scenes.count, 1)
    }

    /// Past the budget the script splits, and every pass stays under it.
    func testALongExchangeSplitsIntoBudgetedPasses() {
        let lines = (0..<8).map { line($0, $0.isMultiple(of: 2) ? "ava" : "ben", words: 60) }
        let scenes = DialoguePlanner.scenes(for: lines, budgetSeconds: 45)
        XCTAssertGreaterThan(scenes.count, 1)
        for scene in scenes {
            let seconds = scene.lines.reduce(0.0) {
                $0 + DialoguePlanner.estimatedSeconds(of: lines[$1].text)
            }
            XCTAssertLessThanOrEqual(seconds, 45.001)
            XCTAssertEqual(Set(scene.voices).count, 2)
        }
        XCTAssertEqual(scenes.flatMap(\.lines), Array(0..<8))
    }

    /// A seam mid-sentence is the audible kind. One speaker holding the floor
    /// past the budget runs long rather than being cut.
    func testASingleSpeakersMonologueIsNotCutMidTurn() {
        let lines = (0..<6).map { line($0, "ava", words: 60) }
        let scenes = DialoguePlanner.scenes(for: lines, budgetSeconds: 45)
        XCTAssertEqual(scenes.count, 1)
        XCTAssertEqual(scenes[0].lines, Array(0..<6))
    }

    /// A turn longer than the whole budget still has to be rendered somewhere.
    func testASingleOversizedTurnIsItsOwnPass() {
        let lines = [line(0, "ava", words: 400), line(1, "ben", words: 10)]
        let scenes = DialoguePlanner.scenes(for: lines, budgetSeconds: 45)
        XCTAssertEqual(scenes.count, 2)
        XCTAssertEqual(scenes[0].lines, [0])
        XCTAssertEqual(scenes[1].lines, [1])
    }

    /// Two speakers with no voices assigned still take turns, so the seam has
    /// somewhere to land — otherwise an unconditioned script never splits.
    func testUnvoicedSpeakersStillSplitOnTheirOwnTurns() {
        let lines = (0..<8).map {
            DialogueLine(index: $0, voiceSlug: nil,
                         text: Array(repeating: "word", count: 60).joined(separator: " "),
                         speakerID: $0.isMultiple(of: 2) ? "S1" : "S2")
        }
        XCTAssertGreaterThan(DialoguePlanner.scenes(for: lines, budgetSeconds: 45).count, 1)
    }

    /// The voice-count rule still wins: a third voice starts a pass whatever
    /// the clock says.
    func testAThirdVoiceStillStartsAPass() {
        let lines = [line(0, "ava", words: 5), line(1, "ben", words: 5),
                     line(2, "cass", words: 5)]
        let scenes = DialoguePlanner.scenes(for: lines, budgetSeconds: 45)
        XCTAssertEqual(scenes.count, 2)
        XCTAssertEqual(scenes[1].lines, [2])
    }

    func testReportCarriesPerPassDurations() {
        let lines = (0..<8).map { line($0, $0.isMultiple(of: 2) ? "ava" : "ben", words: 60) }
        let report = DialoguePlanner.report(for: lines, budgetSeconds: 45)
        XCTAssertEqual(report.sceneCount, report.sceneSeconds.count)
        XCTAssertEqual(report.splitAfterLines.count, report.sceneCount - 1)
        XCTAssertEqual(report.estimatedSeconds,
                       report.sceneSeconds.reduce(0, +), accuracy: 0.001)
        XCTAssertTrue(report.overBudgetScenes.isEmpty)
    }

    /// The UI has to be able to say "this pass runs long" — a monologue that
    /// cannot be split is exactly the case a user needs warning about.
    func testReportFlagsAPassThatCannotBeSplit() {
        let report = DialoguePlanner.report(for: [line(0, "ava", words: 400)],
                                            budgetSeconds: 45)
        XCTAssertEqual(report.overBudgetScenes, [0])
    }
}
