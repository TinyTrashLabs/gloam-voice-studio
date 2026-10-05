import XCTest
@testable import GloamVoiceEditing

/// A voice recorded over a steady noise bed (Morgan Freeman's reference:
/// 10th-percentile 50 ms level -35 dB, 98% of blocks above the -45 dB speech
/// floor) breaks every check tuned for a quiet room: the fork's trailing
/// silence never arrives, a render of pure bed passes as speech. The bed is
/// measured from the reference and the floors move up over it; a clean voice
/// keeps today's -45 / -35 exactly.
final class NoiseBedTests: XCTestCase {
    private let rate = 24000

    /// Deterministic white noise at `db` dBFS RMS (uniform noise: rms = peak / sqrt(3)).
    private func noise(seconds: Double, db: Float, seed: UInt64 = 1) -> [Float] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        let peak = Float(pow(10, Double(db) / 20) * 3.0.squareRoot())
        return (0..<Int(seconds * Double(rate))).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Float(state >> 40) / Float(1 << 24) * 2 - 1) * Float(peak)
        }
    }

    /// Words (0.4 s at -15 dB) and pauses (0.2 s) over a bed at `bedDb`.
    private func voice(seconds: Double, bedDb: Float) -> [Float] {
        let bed = noise(seconds: seconds, db: bedDb)
        return bed.enumerated().map { i, b in
            let t = Double(i) / Double(rate)
            let on = t.truncatingRemainder(dividingBy: 0.6) < 0.4
            return b + (on ? Float(0.25 * sin(2 * .pi * 180 * t)) : 0)
        }
    }

    func testTheFloorOfAVoiceOverABedIsTheBed() {
        let floor = NoiseBed.floorDb(of: voice(seconds: 6, bedDb: -35), sampleRate: rate)
        XCTAssertEqual(floor, -35, accuracy: 1.5)
    }

    func testTheFloorOfACleanVoiceIsFarBelowTheSpeechFloor() {
        let floor = NoiseBed.floorDb(of: voice(seconds: 6, bedDb: -62), sampleRate: rate)
        XCTAssertLessThan(floor, -55)
    }

    func testAFloorIsNeverReadFromNothing() {
        XCTAssertEqual(NoiseBed.floorDb(of: [], sampleRate: rate), -120)
    }

    // The three real references measured 2026-10-02 (10th percentile, 50 ms
    // blocks): Morgan window -35.0, Cruz -47.3 and Jeff -48.5 (the loudest
    // clean ones), Billie -57, Benson -64.

    func testACleanVoiceKeepsTodaysFloorsExactly() {
        for floor in [-64, -57, -48.5, -47.3] as [Float] {
            XCTAssertEqual(NoiseBed.speechFloorDb(noiseFloorDb: floor), -45)
            XCTAssertEqual(NoiseBed.trailingFloorDb(noiseFloorDb: floor), -35)
        }
        XCTAssertEqual(NoiseBed.speechFloorDb(noiseFloorDb: nil), -45)
        XCTAssertEqual(NoiseBed.trailingFloorDb(noiseFloorDb: nil), -35)
        XCTAssertEqual(RenderCheck.speechFloorDb, -45)
    }

    func testABeddedVoiceGetsFloorsOverItsBedAsRendered() {
        // The reference is turned down 2 dB, so its renders' bed is -37: floor -31.
        XCTAssertEqual(NoiseBed.speechFloorDb(noiseFloorDb: -35), -31)
        XCTAssertEqual(NoiseBed.trailingFloorDb(noiseFloorDb: -35), -31)
        XCTAssertEqual(NoiseBed.trailingFloorDb(noiseFloorDb: -25), -21)
    }

    func testTheTrailingFloorNeverDropsBelowTheForksDefault() {
        // A bed just over the "bedded" line: +6 dB is under -35, so -35 stands.
        let floor = NoiseBed.bedAboveDb
        XCTAssertTrue(NoiseBed.isBedded(floor))
        XCTAssertGreaterThanOrEqual(NoiseBed.trailingFloorDb(noiseFloorDb: floor), -35)
    }

    func testOnlyABeddedReferenceIsTurnedDown() {
        XCTAssertEqual(NoiseBed.referenceGainDb(noiseFloorDb: -35), -2)
        for floor in [-64, -57, -48.5, -47.3] as [Float] { XCTAssertEqual(NoiseBed.referenceGainDb(noiseFloorDb: floor), 0) }
        XCTAssertEqual(NoiseBed.referenceGainDb(noiseFloorDb: nil), 0)
    }

    func testAFloorJustUnderTheLineIsStillClean() {
        XCTAssertFalse(NoiseBed.isBedded(NoiseBed.bedAboveDb - 0.1))
    }

    /// The file form measures the clip as an engine clones from it, and
    /// remembers the answer per file and modification date.
    func testAFileIsMeasuredLikeItsSamples() throws {
        let samples = voice(seconds: 6, bedDb: -35)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bed-\(UUID()).wav")
        try VoicePlayer.wavData(samples: samples, sampleRate: rate).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let floor = try XCTUnwrap(NoiseBed.floorDb(of: url))
        XCTAssertEqual(floor, -35, accuracy: 1.5)
        XCTAssertTrue(NoiseBed.isBedded(floor))
        XCTAssertNil(NoiseBed.floorDb(of: URL(fileURLWithPath: "/nonexistent.wav")))
    }
}
