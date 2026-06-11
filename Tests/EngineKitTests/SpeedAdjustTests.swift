import XCTest
@testable import EngineKit

final class SpeedAdjustTests: XCTestCase {
    func testSpeedOneIsIdentity() {
        let samples: [Float] = [0, 0.5, 1.0, 0.5]
        XCTAssertEqual(SpeedAdjust.apply(samples, speed: 1.0), samples)
    }

    func testDoubleSpeedHalvesLength() {
        let samples = [Float](repeating: 0.25, count: 1000)
        XCTAssertEqual(SpeedAdjust.apply(samples, speed: 2.0).count, 500)
    }

    func testHalfSpeedDoublesLength() {
        let samples = [Float](repeating: 0.25, count: 1000)
        XCTAssertEqual(SpeedAdjust.apply(samples, speed: 0.5).count, 2000)
    }

    func testInterpolatesBetweenSamples() {
        // Ramp 0,1,2,3 at half speed: midpoints appear.
        let out = SpeedAdjust.apply([0, 1, 2, 3], speed: 0.5)
        XCTAssertEqual(out.count, 8)
        XCTAssertEqual(out[1], 0.5, accuracy: 1e-6)
        XCTAssertEqual(out[3], 1.5, accuracy: 1e-6)
    }

    func testEmptyInputStaysEmpty() {
        XCTAssertEqual(SpeedAdjust.apply([], speed: 2.0), [])
    }

    func testNearOneSpeedIsIdentity() {
        // Match upstream guard: |speed-1| <= 1e-6 → unchanged.
        let samples: [Float] = [0, 1]
        XCTAssertEqual(SpeedAdjust.apply(samples, speed: 1.0000005), samples)
    }
}
