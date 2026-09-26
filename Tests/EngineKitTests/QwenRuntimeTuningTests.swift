import XCTest
import MLXAudioTTS
@testable import EngineKit

/// The fork ships every Qwen3-TTS speed/correctness switch defaulting to OFF,
/// so a host that never sets them runs the slow module path with the inaccurate
/// RoPE chain — which is what this app did until 2026-09-17. iOS sets all five
/// in `QwenMLXEngine.loaded()`; these assert the Mac does the same.
final class QwenRuntimeTuningTests: XCTestCase {
    private func resetToForkDefaults() {
        Qwen3TTSModel.fastRope = false
        Qwen3TTSModel.greedySubCodes = false
        Qwen3TTSModel.fusedLayers = false
        Qwen3TTSModel.pipelineFrame = false
        Qwen3TTSModel.asyncDecode = 0
        Qwen3TTSModel.eosGreedyStop = false
        Qwen3TTSModel.trailingSilenceStopSeconds = 0
    }

    override func tearDown() {
        QwenRuntimeTuning.apply()   // leave the process in the shipping config
        super.tearDown()
    }

    /// The measured-fastest configuration from the on-device spike. `fastRope`
    /// is also a correctness fix: the original module chain is off by 0.20 at
    /// position 200 and varies with evaluation order (fork, 2026-09-09).
    func testApplyTurnsOnTheMeasuredFastestConfiguration() {
        resetToForkDefaults()
        QwenRuntimeTuning.apply()
        XCTAssertTrue(Qwen3TTSModel.fastRope)
        XCTAssertTrue(Qwen3TTSModel.greedySubCodes)
        XCTAssertTrue(Qwen3TTSModel.fusedLayers)
        XCTAssertTrue(Qwen3TTSModel.pipelineFrame)
        XCTAssertEqual(Qwen3TTSModel.asyncDecode, 1)
    }

    /// ~1 render in 20 misses the end-of-speech token and runs to the token cap
    /// with ~11 s of low hiss. Stop on EOS-as-argmax, with a silence backstop
    /// long enough to sit through a demon voice's dramatic pause (2-2.5 s
    /// measured; 1.5 s truncated real speech).
    func testApplyArmsTheMissedEOSStops() {
        resetToForkDefaults()
        QwenRuntimeTuning.apply()
        XCTAssertTrue(Qwen3TTSModel.eosGreedyStop)
        XCTAssertEqual(Qwen3TTSModel.trailingSilenceStopSeconds, 3.0, accuracy: 0.0001)
    }

    /// The bench escape hatch is opt-out only: anything but "off" ships tuned,
    /// so a typo cannot silently un-tune the app.
    func testTuningIsOnUnlessExplicitlyDisabled() {
        XCTAssertTrue(QwenRuntimeTuning.isEnabled,
                      "GLOAM_QWEN_TUNING is unset in the test env, so tuning must be on")
    }

    /// Idempotent: it runs before every model load, not once at startup.
    func testApplyIsIdempotent() {
        QwenRuntimeTuning.apply()
        QwenRuntimeTuning.apply()
        XCTAssertTrue(Qwen3TTSModel.fusedLayers)
        XCTAssertTrue(Qwen3TTSModel.fastRope)
    }
}
