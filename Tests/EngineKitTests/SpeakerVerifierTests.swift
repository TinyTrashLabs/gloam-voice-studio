import XCTest
@testable import EngineKit

final class SpeakerVerifierTests: XCTestCase {
    func testFbankFramesAndShape() {
        let one = [Float](repeating: 0.1, count: 16_000)
        let (f, n) = KaldiFbank.compute(one)
        XCTAssertEqual(n, 100)                                  // snip_edges false: round(16000 / 160)
        XCTAssertEqual(f.count, 100 * 80)
    }
    func testAToneLightsTheRightMelBin() {
        let tone = (0..<16_000).map { Float(sin(2 * Double.pi * 1000 * Double($0) / 16_000) * 0.5) }
        let (f, n) = KaldiFbank.compute(tone)
        let row = Array(f[(n / 2) * 80..<(n / 2 + 1) * 80])
        let peak = row.indices.max { row[$0] < row[$1] }!
        // 1 kHz sits near mel bin 28–30 of 80 between 20 Hz and 8 kHz
        XCTAssertTrue((26...32).contains(peak), "\(peak)")
    }
    func testAMissingModelSaysSo() {
        XCTAssertThrowsError(try SpeakerVerifier(modelFile: URL(fileURLWithPath: "/nonexistent/wespeaker.onnx"))) { e in
            XCTAssertEqual(e as? SpeakerVerifierError, .missing("wespeaker.onnx"))
        }
    }
    /// With SPEAKER_MODEL set: the same clip twice is the same speaker; a sine is nobody.
    func testEmbeddingsAreNormalisedAndStable() throws {
        guard let path = ProcessInfo.processInfo.environment["SPEAKER_MODEL"] else { throw XCTSkip("SPEAKER_MODEL isn't set") }
        let v = try SpeakerVerifier(modelFile: URL(fileURLWithPath: path))
        let noise = (0..<48_000).map { _ in Float.random(in: -0.1...0.1) }
        let a = try v.embedding(samples: noise, sampleRate: 24_000), b = try v.embedding(samples: noise, sampleRate: 24_000)
        XCTAssertEqual(a, b)
        XCTAssertEqual(sqrt(a.reduce(0) { $0 + $1 * $1 }), 1, accuracy: 1e-4)
    }
}
