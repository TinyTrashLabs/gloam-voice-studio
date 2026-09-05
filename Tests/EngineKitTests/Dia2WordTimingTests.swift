import XCTest
@testable import EngineKit

/// Dia2 reports where each generated word STARTS and nothing else. Deriving
/// the end is the whole job, and getting it wrong is invisible: `end: start`
/// type-checks, reads fine, and silently makes every word zero-length.
final class Dia2WordTimingTests: XCTestCase {
    func testAWordEndsWhereTheNextOneBegins() {
        let words = Dia2WordTiming.aligned([("Good", 0.0), ("evening", 0.4), ("all", 0.9)],
                                           sampleCount: 24_000, sampleRate: 24_000)
        XCTAssertEqual(words.map(\.end), [0.4, 0.9, 1.0])
    }

    /// The last word has no successor, so it runs to the end of the audio it
    /// arrived with.
    func testTheLastWordRunsToTheEndOfTheAudio() {
        let words = Dia2WordTiming.aligned([("hello", 0.25)],
                                           sampleCount: 48_000, sampleRate: 24_000)
        XCTAssertEqual(words.first?.end, 2.0)
    }

    /// The bug this replaced: a zero-length word makes any span measured from
    /// it empty, so slicing a speaker's audio out of a take yields silence.
    func testWordsAreNeverZeroLength() {
        let words = Dia2WordTiming.aligned([("a", 0.0), ("b", 0.5)],
                                           sampleCount: 24_000, sampleRate: 24_000)
        XCTAssertTrue(words.allSatisfy { $0.end > $0.start })
    }

    /// A word reported past the end of its chunk must not produce a backwards
    /// span; timings come from a frame counter and audio from a decoder, and
    /// the two can disagree by a frame at a boundary.
    func testATrailingWordPastTheAudioEndDoesNotGoBackwards() {
        let words = Dia2WordTiming.aligned([("late", 3.0)],
                                           sampleCount: 24_000, sampleRate: 24_000)
        XCTAssertEqual(words.first?.end, 3.0)
        XCTAssertFalse(words.contains { $0.end < $0.start })
    }

    func testNoWordsIsNotACrash() {
        XCTAssertTrue(Dia2WordTiming.aligned([], sampleCount: 0, sampleRate: 24_000).isEmpty)
    }
}
