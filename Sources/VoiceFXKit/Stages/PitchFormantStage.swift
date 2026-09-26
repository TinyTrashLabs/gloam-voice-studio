//  PitchFormantStage.swift
//
//  Swift face of the signalsmith-stretch shim (MIT, Geraint Luff /
//  Signalsmith Audio). See Sources/CSignalsmithStretch.

import Foundation
import CSignalsmithStretch

/// Shifts pitch and formants independently.
///
/// The independence is the point. Dropping formants FURTHER than pitch implies
/// a vocal tract too large for the body producing the sound, which is what the
/// ear reads as monstrous. `AVAudioUnitTimePitch` cannot express this — it
/// offers formant preservation only as an on/off flag — and that is why this
/// library is a dependency rather than a convenience.
public final class PitchFormantStage: FXStage {
    private let transposeSemitones: Float
    private let formantSemitones: Float
    /// Rough f0 hint for formant analysis. 0 = let the library detect it.
    private let formantBaseHz: Float
    private var handle: GVFXStretchRef?

    /// Sane clamp so an extreme preset can't drive the library argument to a
    /// wild value.
    private static let formantArgumentClamp: Float = 36

    public init(transposeSemitones: Float,
                formantSemitones: Float = 0,
                formantBaseHz: Float = 0) {
        self.transposeSemitones = transposeSemitones
        self.formantSemitones = formantSemitones
        self.formantBaseHz = formantBaseHz
    }

    deinit {
        if let handle { gvfx_stretch_destroy(handle) }
    }

    public var latencyFrames: Int {
        guard let handle else { return 0 }
        return Int(gvfx_stretch_input_latency(handle) + gvfx_stretch_output_latency(handle))
    }

    public func prepare(sampleRate: Double, maxBlock: Int) {
        if let handle { gvfx_stretch_destroy(handle) }
        handle = gvfx_stretch_create(1, Float(sampleRate))
        guard let handle else { return }   // degrades to pass-through
        gvfx_stretch_set_transpose_semitones(handle, transposeSemitones)

        // The library's formant-semitones sign is natural (negative = formants
        // down), confirmed on real speech across five independent spectral
        // metrics — no inversion needed here. Just clamp against extreme
        // preset values.
        let clamped = max(-Self.formantArgumentClamp, min(Self.formantArgumentClamp, formantSemitones))
        gvfx_stretch_set_formant_semitones(handle, clamped)

        // EMPIRICAL: the library documents its formant-base argument as a
        // fundamental-frequency estimate relative to Nyquist, not Hz, despite
        // the shim header's "in Hz" wording — passing raw Hz degenerates the
        // envelope estimator and silently disables formant processing. 0 is
        // the documented "detect the pitch yourself" path and is passed
        // through unchanged.
        let normalizedBase = formantBaseHz == 0 ? 0 : formantBaseHz / Float(sampleRate)
        gvfx_stretch_set_formant_base(handle, normalizedBase)
    }

    public func process(_ input: UnsafePointer<Float>,
                        _ output: UnsafeMutablePointer<Float>,
                        frames: Int) {
        guard let handle else {
            // A silent Furby is a worse failure than an unprocessed one.
            output.update(from: input, count: frames)
            return
        }
        gvfx_stretch_process(handle, input, Int32(frames), output, Int32(frames))
    }

    public func reset() {
        if let handle { gvfx_stretch_reset(handle) }
    }
}
