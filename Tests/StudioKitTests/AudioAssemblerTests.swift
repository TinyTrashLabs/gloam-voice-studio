import XCTest
@testable import StudioKit

final class AudioAssemblerTests: XCTestCase {
    func testStitchInsertsGapBetweenClips() {
        let a = PCM16.data(from: [0.5, 0.5])          // 2 samples
        let b = PCM16.data(from: [-0.5])              // 1 sample
        let out = AudioAssembler.stitch([a, b], sampleRate: 10, gapSeconds: 0.5)
        // 2 + 5 (0.5 s @ 10 Hz) + 1 samples = 8 samples = 16 bytes
        XCTAssertEqual(out.count, 16)
        // gap region is silence
        let mid = out.subdata(in: 4..<14)
        XCTAssertTrue(mid.allSatisfy { $0 == 0 })
    }

    func testStitchSingleClipHasNoGap() {
        let a = PCM16.data(from: [0.5, 0.5])
        XCTAssertEqual(AudioAssembler.stitch([a], sampleRate: 10, gapSeconds: 1.0), a)
    }

    func testNormalizePeakScalesToTarget() {
        let pcm = PCM16.data(from: [0.25, -0.5])      // peak 0.5 → 16383
        let out = AudioAssembler.normalizePeak(pcm)
        let values = out.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            .map { Int16(littleEndian: $0) }
        // target 0.98 full scale: peak 16383 → ~32113, first sample scales ~×1.96
        XCTAssertTrue(abs(Int(values[1]) - (-32113)) <= 40)
        XCTAssertTrue(abs(Int(values[0]) - 16056) <= 40)
    }

    func testNormalizeSilenceIsIdentity() {
        let pcm = PCM16.data(from: [0, 0, 0])
        XCTAssertEqual(AudioAssembler.normalizePeak(pcm), pcm)
    }
}
