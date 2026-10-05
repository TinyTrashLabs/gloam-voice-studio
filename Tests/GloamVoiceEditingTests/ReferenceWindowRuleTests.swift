import XCTest
@testable import GloamVoiceEditing

final class ReferenceWindowRuleTests: XCTestCase {
    private let sr = 24_000

    // MARK: bounds

    func testWindowStaysInsideTheMasterAndTheCap() {
        // A 58 s master, handles inside it.
        let b = ReferenceWindowRule.clamp(start: 5, end: 20, sourceSeconds: 58, movedStart: true)
        XCTAssertEqual(b, .init(start: 5, end: 20))
        // Past the end.
        XCTAssertEqual(ReferenceWindowRule.clamp(start: 50, end: 70, sourceSeconds: 58, movedStart: false).end, 58)
        // Longer than the cap: the edge that moved wins.
        XCTAssertEqual(ReferenceWindowRule.clamp(start: 0, end: 40, sourceSeconds: 58, movedStart: false), .init(start: 10, end: 40))
        XCTAssertEqual(ReferenceWindowRule.clamp(start: 0, end: 40, sourceSeconds: 58, movedStart: true), .init(start: 0, end: 30))
        // Shorter than the minimum: pushed apart.
        XCTAssertEqual(ReferenceWindowRule.clamp(start: 10, end: 11, sourceSeconds: 58, movedStart: true).seconds, 3, accuracy: 1e-9)
        XCTAssertEqual(ReferenceWindowRule.clamp(start: 10, end: 11, sourceSeconds: 58, movedStart: false), .init(start: 8, end: 11))
        // At the very end, start gives way.
        XCTAssertEqual(ReferenceWindowRule.clamp(start: 57, end: 58, sourceSeconds: 58, movedStart: true), .init(start: 55, end: 58))
    }

    // MARK: transcript gate

    func testWordsPerSecondGate() {
        XCTAssertNil(ReferenceWindowRule.transcriptProblem("one two three four five six seven eight nine ten twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twentyone twentytwo twentythree twentyfour twentyfive", seconds: 10))
        XCTAssertNotNil(ReferenceWindowRule.transcriptProblem("only ten words for thirty seconds of speech is few", seconds: 30), "under-counts the audio")
        XCTAssertNotNil(ReferenceWindowRule.transcriptProblem(Array(repeating: "w", count: 40).joined(separator: " "), seconds: 5), "more than the audio holds")
        XCTAssertNotNil(ReferenceWindowRule.transcriptProblem("   ", seconds: 10))
        XCTAssertEqual(ReferenceWindowRule.wordsPerSecond("a b c d", seconds: 2), 2)
    }

    // MARK: the cut

    /// Silence, then speech-like bursts.
    private func clip(leadIn: Double, seconds: Double) -> [Float] {
        var out = [Float](repeating: 0, count: Int(leadIn * Double(sr)))
        let n = Int(seconds * Double(sr))
        for i in 0 ..< n {
            let t = Double(i) / Double(sr)
            let on = t.truncatingRemainder(dividingBy: 0.6) < 0.4   // 400 ms on, 200 ms off
            out.append(on ? 0.4 * Float(sin(2 * .pi * 180 * t)) : 0)
        }
        return out
    }

    func testCutReturnsTheWholeClipWhenItFits() {
        let c = clip(leadIn: 0, seconds: 10)
        let r = ReferenceWindowRule.cut(samples: c, sampleRate: sr, maxSeconds: 15)
        XCTAssertEqual(r.samples.count, c.count)
        XCTAssertEqual(r.start, 0)
    }

    func testCutSkipsLeadInAndEndsInAPause() {
        let c = clip(leadIn: 2, seconds: 40)
        let r = ReferenceWindowRule.cut(samples: c, sampleRate: sr, maxSeconds: 15)
        XCTAssertLessThanOrEqual(r.samples.count, 15 * sr)
        XCTAssertGreaterThanOrEqual(r.samples.count, Int(15 * 0.6) * sr)
        XCTAssertEqual(Double(r.start) / Double(sr), 1.9, accuracy: 0.05, "starts 100 ms before the first speech")
        // Ends where the signal was quiet.
        let tail = r.samples.suffix(sr / 100)
        XCTAssertLessThan(tail.map(abs).max() ?? 1, 0.05)
    }

    func testSliceAndEnvelope() {
        let c = clip(leadIn: 0, seconds: 4)
        let s = ReferenceWindowRule.slice(c, sampleRate: sr, bounds: .init(start: 1, end: 3))
        XCTAssertEqual(s.count, 2 * sr)
        XCTAssertEqual(s.first, 0, "faded in")
        let env = ReferenceWindowRule.envelope(c, bins: 8)
        XCTAssertEqual(env.count, 8)
        XCTAssertEqual(env.max(), 1)
        XCTAssertEqual(ReferenceWindowRule.envelope([], bins: 4), [0, 0, 0, 0])
    }

    // MARK: derivedFrom
}
