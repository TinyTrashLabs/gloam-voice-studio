import XCTest
import CSignalsmithStretch
@testable import VoiceFXKit

final class StretchShimTests: XCTestCase {
    /// Proves the C++ builds, links, and is reachable from Swift. If this
    /// fails, nothing downstream of it can work.
    func testCreateAndDestroy() {
        let ref = gvfx_stretch_create(1, 48_000)
        XCTAssertNotNil(ref)
        gvfx_stretch_destroy(ref)
    }

    func testRejectsInvalidConfiguration() {
        XCTAssertNil(gvfx_stretch_create(0, 48_000))
        XCTAssertNil(gvfx_stretch_create(1, 0))
    }

    func testReportsLatency() {
        let ref = gvfx_stretch_create(1, 48_000)
        defer { gvfx_stretch_destroy(ref) }
        // A block-based shifter must declare non-zero latency; zero would mean
        // the preset never configured.
        XCTAssertGreaterThan(gvfx_stretch_output_latency(ref), 0)
    }

    func testProcessProducesSignal() {
        let ref = gvfx_stretch_create(1, 48_000)
        defer { gvfx_stretch_destroy(ref) }
        gvfx_stretch_set_transpose_semitones(ref, -7)
        let input = (0..<48_000).map { Float(sin(2 * Double.pi * 220 * Double($0) / 48_000)) }
        var output = [Float](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { i in
            output.withUnsafeMutableBufferPointer { o in
                gvfx_stretch_process(ref, i.baseAddress!, Int32(input.count),
                                     o.baseAddress!, Int32(input.count))
            }
        }
        XCTAssertTrue(output.allSatisfy { $0.isFinite })
        // Skip the latency region, then require real output.
        let tail = Array(output[24_000...])
        let rms = (tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count)).squareRoot()
        XCTAssertGreaterThan(rms, 0.05, "shifted output should carry energy")
    }
}
