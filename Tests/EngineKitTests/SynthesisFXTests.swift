import XCTest
import VoiceFXKit
@testable import EngineKit

final class SynthesisFXTests: XCTestCase {
    /// A request without `fx` must behave exactly as before. This route is how
    /// everything off-machine hears a voice; a silent behaviour change here
    /// would be felt everywhere.
    func testDefaultRequestHasNoFX() {
        let request = SynthesisRequest(text: "hello")
        XCTAssertNil(request.fx)
    }

    func testRequestCarriesPreset() throws {
        let preset = try XCTUnwrap(FXPreset.builtIn(named: "demon"))
        let request = SynthesisRequest(text: "hello", fx: preset)
        XCTAssertEqual(request.fx?.name, "demon")
    }

    /// Applying a preset must actually change the samples, and must not break
    /// their length — callers size buffers from the result.
    func testApplyingFXPreservesLengthAndChangesAudio() throws {
        let preset = try XCTUnwrap(FXPreset.builtIn(named: "demon"))
        let input = (0..<9600).map { Float(0.3 * sin(Double($0) * 0.05)) }
        let chain = FXChain.make(from: preset)
        chain.prepare(sampleRate: 48_000, maxBlock: 4096)
        let out = chain.applyWhole(input)
        XCTAssertEqual(out.count, input.count)
        var diff: Float = 0
        for i in 0..<input.count { diff += abs(out[i] - input[i]) }
        XCTAssertGreaterThan(diff / Float(input.count), 0.01, "fx did not alter the audio")
    }
}
