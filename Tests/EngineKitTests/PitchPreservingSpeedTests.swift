import XCTest
import Accelerate
@testable import EngineKit

final class PitchPreservingSpeedTests: XCTestCase {
    private let rate = 44100

    private func sine(_ hz: Float, seconds: Float, offsetSeconds: Float = 0) -> [Float] {
        let n = Int(seconds * Float(rate)), off = Int(offsetSeconds * Float(rate))
        return (0..<n).map { $0 < off ? 0 : 0.5 * sin(2 * .pi * hz * Float($0) / Float(rate)) }
    }

    func testSpeedOneIsIdentity() {
        let x = sine(220, seconds: 0.5)
        XCTAssertEqual(PitchPreservingSpeed.apply(x, speed: 1.0, sampleRate: rate), x)
    }

    func testLengthScalesWithSpeed() {
        let x = sine(220, seconds: 2)
        let y = PitchPreservingSpeed.apply(x, speed: 1.2, sampleRate: rate)
        let want = Double(x.count) / 1.2
        XCTAssertEqual(Double(y.count), want, accuracy: want * 0.01)
    }

    /// Dominant frequency by zero-crossing rate over the steady middle.
    private func dominantHz(_ y: [Float]) -> Float {
        let a = y.count / 4, b = 3 * y.count / 4
        var crossings = 0
        for i in (a + 1)..<b where (y[i - 1] < 0) != (y[i] < 0) { crossings += 1 }
        return Float(crossings) / 2 / (Float(b - a) / Float(rate))
    }

    func testPitchIsPreserved() {
        let x = sine(220, seconds: 2)
        let y = PitchPreservingSpeed.apply(x, speed: 1.2, sampleRate: rate)
        XCTAssertEqual(dominantHz(y), 220, accuracy: 220 * 0.02)
        // The resample it replaces would land at 264 Hz.
        XCTAssertEqual(dominantHz(SpeedAdjust.apply(x, speed: 1.2)), 264, accuracy: 264 * 0.02)
    }

    func testNoLatencyGap() {
        // 100 ms of silence, then a tone: output onset (scaled) must match.
        let x = sine(220, seconds: 2, offsetSeconds: 0.1)
        let y = PitchPreservingSpeed.apply(x, speed: 1.2, sampleRate: rate)
        let first = y.firstIndex { abs($0) > 0.25 } ?? y.count  // half amplitude: ignores window pre-echo
        let expected = Int(0.1 * Float(rate) / 1.2)
        XCTAssertEqual(Double(first), Double(expected), accuracy: 0.005 * Double(rate))
    }

    func testTooShortInputFallsBackNotSilent() {
        let x = sine(220, seconds: 0.01)
        let y = PitchPreservingSpeed.apply(x, speed: 1.2, sampleRate: rate)
        XCTAssertFalse(y.isEmpty)
        XCTAssertTrue(y.contains { abs($0) > 0.1 })
    }
}
