import XCTest
@testable import StudioKit

final class RefAudioCombinerTests: XCTestCase {
    private func toneWAV(seconds: Double, amplitude: Float = 0.5,
                         sampleRate: Int = 24_000) -> Data {
        let count = Int(seconds * Double(sampleRate))
        let samples = (0..<count).map { i in
            amplitude * sin(Float(i) * 2 * .pi * 220 / Float(sampleRate))
        }
        return WAVEncoder.encode(pcm16: PCM16.data(from: samples), sampleRate: sampleRate)
    }

    func testCombineConcatenatesWithGapAndJoinsTranscripts() throws {
        let a = toneWAV(seconds: 1.0)
        let b = toneWAV(seconds: 2.0, amplitude: 0.1)   // quiet clip gets normalized up
        let (wav, transcript) = try RefAudioCombiner.combine(
            clips: [(a, "first clip."), (b, " second clip. ")])

        XCTAssertEqual(transcript, "first clip. second clip.")
        let decoded = try RefAudioCombiner.decodeMono(wav)
        // 1s + 0.25s gap + 2s at 44.1k, generous tolerance for resampler edges.
        let expected = Int(3.25 * RefAudioCombiner.targetSampleRate)
        XCTAssertEqual(Double(decoded.count), Double(expected),
                       accuracy: Double(expected) * 0.02)
        // Both clips should approach full scale after per-clip normalization.
        let firstHalfPeak = decoded.prefix(40_000).map(abs).max() ?? 0
        let lastHalfPeak = decoded.suffix(40_000).map(abs).max() ?? 0
        XCTAssertGreaterThan(firstHalfPeak, 0.8)
        XCTAssertGreaterThan(lastHalfPeak, 0.8)
    }

    func testSingleClipRoundTrips() throws {
        let (wav, transcript) = try RefAudioCombiner.combine(clips: [(toneWAV(seconds: 1.5), "solo")])
        XCTAssertEqual(transcript, "solo")
        XCTAssertGreaterThan(wav.count, 44)   // header + payload
    }

    func testGarbageDataThrows() {
        XCTAssertThrowsError(try RefAudioCombiner.combine(
            clips: [(Data([0, 1, 2, 3]), "junk")]))
    }
}
