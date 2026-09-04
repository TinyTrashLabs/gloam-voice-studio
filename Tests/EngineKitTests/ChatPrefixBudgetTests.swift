import XCTest
@testable import EngineKit

final class ChatPrefixBudgetTests: XCTestCase {
    private func words(_ count: Int) -> [AlignedWordTiming] {
        (0 ..< count).map {
            AlignedWordTiming(text: "w\($0)", start: Double($0), end: Double($0) + 0.5)
        }
    }

    /// A long prior turn is trimmed to its TAIL: the most recent speech is what
    /// the reply should sound like a response to.
    func testLongPrefixKeepsTheEnd() {
        let samples = [Float](repeating: 0.1, count: 24000 * 40)
        let prefix = ChatPrefixBudget.trim(words(40), samples: samples,
                                           sampleRate: 24000, maxSeconds: 15)
        XCTAssertLessThanOrEqual(Double(prefix.samples.count) / 24000.0, 15.1)
        XCTAssertEqual(prefix.words.last?.text, "w39", "must keep the most recent words")
        XCTAssertGreaterThan(prefix.words.count, 0)
    }

    /// Trimmed timings are rebased to zero, or the model waits out the gap.
    func testTrimmedTimingsAreRebasedToZero() {
        let samples = [Float](repeating: 0.1, count: 24000 * 40)
        let prefix = ChatPrefixBudget.trim(words(40), samples: samples,
                                           sampleRate: 24000, maxSeconds: 15)
        XCTAssertEqual(prefix.words.first?.start ?? -1, 0, accuracy: 0.001)
    }

    /// Starting halfway through the first retained word gives Dia2 audio that
    /// contradicts its timing grid and weakens voice conditioning.
    func testLongPrefixStartsAtAWholeWordBoundary() {
        let sampleRate = 10
        let samples = (0 ..< 40).map(Float.init)
        let prefix = ChatPrefixBudget.trim(words(4), samples: samples,
                                           sampleRate: sampleRate, maxSeconds: 1.6)

        XCTAssertEqual(prefix.samples.first, 30,
                       "the first PCM frame must match the retained word at 3 seconds")
        XCTAssertEqual(prefix.words.first?.text, "w3")
        XCTAssertEqual(prefix.words.first?.start ?? -1, 0, accuracy: 0.001)
    }

    func testShortPrefixIsUnchanged() {
        let samples = [Float](repeating: 0.1, count: 24000 * 3)
        let prefix = ChatPrefixBudget.trim(words(3), samples: samples,
                                           sampleRate: 24000, maxSeconds: 15)
        XCTAssertEqual(prefix.samples.count, samples.count)
        XCTAssertEqual(prefix.words.count, 3)
    }

    /// A zero sample rate is a caller bug, not a crash: hand the clip back.
    func testAnInvalidSampleRateIsHandledRatherThanDividingByZero() {
        let prefix = ChatPrefixBudget.trim(words(3), samples: [0.1, 0.2],
                                           sampleRate: 0, maxSeconds: 15)
        XCTAssertEqual(prefix.samples.count, 2)
        XCTAssertEqual(prefix.words.count, 3)
    }
}
