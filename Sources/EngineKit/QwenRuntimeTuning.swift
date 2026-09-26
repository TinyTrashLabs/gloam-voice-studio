import Foundation
import MLXAudioTTS

/// Qwen3-TTS runtime switches, applied before the model is loaded.
///
/// The fork ships every one of these defaulting to OFF (`Qwen3TTS.swift`:
/// `fastRope = false`, `fusedLayers = false`), so a host that sets nothing runs
/// the slow module decoder path with the inaccurate RoPE chain. iOS has set
/// them since the on-device spike (`QwenMLXEngine.loaded()`); this Mac app set
/// none of them until 2026-09-17, which is why its Qwen was no faster than the
/// phone's despite far better hardware.
///
/// Statics on the model class, so they must be set BEFORE the first generate.
enum QwenRuntimeTuning {
    /// Silence backstop once speech has been heard. iOS uses 1.5 s; the Mac
    /// uses 3 s because the cloned demon voices pace like their references —
    /// 2 to 2.5 s mid-line pauses are normal for them, and at 1.5 s the
    /// backstop cut 3 of 4 `qwen3-0.6b` renders off mid-sentence (fork
    /// probe, 2026-09-18, WAVs inspected). The cost is 3 s of hiss instead of
    /// 1.5 on the ~1-in-20 render that misses its EOS.
    static let trailingSilenceStop: Double = 3.0

    /// Set `GLOAM_QWEN_TUNING=off` to leave the fork's defaults alone. Exists so
    /// the switches can be A/B'd end to end on real text — the layer-step
    /// microbench cannot see what sampling and stop behaviour do to a whole
    /// render, and Qwen's stop length varies enough run to run that an A/B
    /// needs several renders per arm.
    static var isEnabled: Bool { setting != "off" }

    private static var setting: String {
        ProcessInfo.processInfo.environment["GLOAM_QWEN_TUNING"]?.lowercased() ?? ""
    }

    /// A comma list ("rope,greedy,fused") turns on only those switches, so one
    /// can be attributed at a time; anything else (including unset) ships the
    /// full set. The stop fixes always apply — they are a correctness fix, not
    /// a speed knob, and a bench arm without them measures hiss.
    private static func wants(_ name: String) -> Bool {
        let s = setting
        guard s.contains(",") || ["rope", "greedy", "fused", "pipeline", "async"].contains(s) else { return true }
        return s.split(separator: ",").contains(Substring(name))
    }

    static func apply() {
        guard isEnabled else { return }
        // The measured-fastest configuration from the on-device spike: fused
        // RoPE in both attentions, argmax for sub-codebooks 1...15, and the
        // single-token decoder layers as fused Metal kernels.
        //
        // `fastRope` is a CORRECTNESS fix as much as a speed one: measured
        // against an exact Double host RoPE, `MLXFast.RoPE` is within 2e-4 at
        // position 1000, while the original module chain is off by 0.019 at
        // position 9 and 0.20 at position 200 — and varies with evaluation
        // order (fork probe, 2026-09-09).
        Qwen3TTSModel.fastRope = wants("rope")
        Qwen3TTSModel.greedySubCodes = wants("greedy")
        Qwen3TTSModel.fusedLayers = wants("fused")
        // Dispatch each stage's graph as soon as it is built (talker, then
        // each of the 15 code-predictor sub-steps) instead of one eval per
        // frame, so the GPU runs stage k while Swift builds stage k+1. Same
        // graph, same audio for a seed. Mac profile probe, best of 4 (fork
        // `QwenMacProfileProbe`, 2026-09-18): mobile 4-bit 45.0 → 48.1 f/s,
        // 0.6B 8-bit 36.5 → 38.8, and the run-to-run spread collapsed (the
        // worst mobile render went 31 → 47 f/s).
        Qwen3TTSModel.pipelineFrame = wants("pipeline")
        // Decode each 1 s streaming chunk on a background queue (same GPU
        // stream) so the loop never waits for the codec: ~20% of the frame
        // on the 0.6B models. Bit-identical output (md5 over 6 renders).
        // Mode 2 (a fresh stream per chunk) measured no better. Mobile 4-bit
        // 48.1 → 53.7 f/s, 0.6B 8-bit 38.8 → 39.7.
        Qwen3TTSModel.asyncDecode = wants("async") ? 1 : 0
        // The fused step runs in hybrid mode — MLX's quantizedMM for every
        // projection (q/k/v and gate/up concatenated once per layer), custom
        // kernels only for the glue. That beat both the module path and
        // all-custom matvecs on the phone (15.6 f/s vs 11.9) and on the Mac
        // (layer step 212 µs vs 320). It is the fork's default and
        // `Qwen3TTSFusedStep` is internal to MLXAudioTTS, so there is nothing
        // to set here — `fusedLayers` above is what selects it. Since
        // 2026-09-18 the hybrid step also takes the 8-bit checkpoints
        // (0.6B 8-bit: 32.4 → 36.5 f/s), so every Qwen backend gains, not
        // only the 4-bit mobile bake.
        // About 1 render in 20 misses the end-of-speech token and runs to the
        // token cap with ~11 s of low hiss (upstream QwenLM/Qwen3-TTS #118).
        // Stop when EOS is the talker's argmax even if the sampler skipped it,
        // with a near-silence backstop.
        Qwen3TTSModel.eosGreedyStop = true
        Qwen3TTSModel.trailingSilenceStopSeconds = trailingSilenceStop
    }
}
