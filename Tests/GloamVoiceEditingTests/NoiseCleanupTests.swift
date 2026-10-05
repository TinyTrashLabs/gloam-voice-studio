import XCTest
@testable import GloamVoiceEditing

final class NoiseCleanupTests: XCTestCase {
    private func q(floor: Float, speech: Float = -18) -> RecordingCheck.Quality {
        .init(seconds: 12, speechDb: speech, noiseFloorDb: floor, clippedFraction: 0)
    }
    func testCleanTakeIsNotOfferedCleanup() {
        XCTAssertFalse(NoiseCleanup.worthOffering(q(floor: -66)))   // 48 dB SNR
    }
    func testNoisyTakeIsOfferedCleanup() {
        XCTAssertTrue(NoiseCleanup.worthOffering(q(floor: -40)))    // 22 dB
    }
    func testTakeTooNoisyToAcceptIsStillOfferedCleanup() {
        XCTAssertTrue(NoiseCleanup.worthOffering(q(floor: -30)))    // 12 dB: rescue it
    }
    func testMixLeavesTheNoisyInputAtTheLimit() {
        let dry = [Float](repeating: 1, count: 10), wet = [Float](repeating: 0, count: 10)
        let out = NoiseCleanup.mix(dry: dry, wet: wet, attenuationLimitDb: 20)
        XCTAssertEqual(out[0], 0.1, accuracy: 1e-4)
    }
    func testLagFindsADelayedCopy() {
        let a: [Float] = (0..<2000).map { sin(Float($0) * 0.05) * Float($0 % 97) / 97 }
        let b = [Float](repeating: 0, count: 30) + a.dropLast(30)
        XCTAssertEqual(NoiseCleanup.lag(a, b, maxLag: 200), 30)
    }
}
