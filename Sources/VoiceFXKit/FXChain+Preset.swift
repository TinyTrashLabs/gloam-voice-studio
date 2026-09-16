import Foundation

public extension FXChain {
    /// Assembles the chain a preset describes.
    ///
    /// Order is fixed and deliberate:
    ///   highpass → pitch/formant (+ parallel detune) → ring mod → drive
    ///   → bitcrush → DC block → reverb → lowpass → limiter
    ///
    /// DC block sits after the waveshaper because asymmetric drive introduces
    /// an offset, and DC entering the reverb wastes headroom the limiter would
    /// then have to claw back. The limiter is last, always.
    static func make(from preset: FXPreset) -> FXChain {
        var stages: [FXStage] = []

        if let hz = preset.highpassHz, hz > 0 {
            stages.append(ButterworthStage(kind: .highpass, frequency: hz))
        }

        if let pitch = preset.pitch {
            let main = PitchFormantStage(transposeSemitones: pitch.transposeSemitones,
                                         formantSemitones: pitch.formantSemitones,
                                         formantBaseHz: pitch.formantBaseHz)
            if let detune = preset.detune {
                let branch = PitchFormantStage(transposeSemitones: detune.transposeSemitones,
                                               formantSemitones: detune.formantSemitones,
                                               formantBaseHz: detune.formantBaseHz)
                // ONE stage holding both shifters, not two stages in series —
                // in series the branch would shift the main path's output and
                // the two transpositions would compose instead of doubling.
                stages.append(ParallelMixStage(primary: main, branch: branch,
                                               primaryGain: 1.0,
                                               branchGain: detune.gain))
            } else {
                stages.append(main)
            }
        }

        if let ring = preset.ringMod, ring.mix > 0 {
            stages.append(RingModStage(frequency: ring.frequencyHz, mix: ring.mix))
        }

        if let drive = preset.drive {
            stages.append(DriveStage(preGain: drive.preGain,
                                     postGain: drive.postGain,
                                     shape1: drive.shape1,
                                     shape2: drive.shape2))
        }

        if let crush = preset.bitCrush {
            stages.append(BitCrushStage(bitDepth: crush.bitDepth,
                                        targetRate: crush.targetRateHz))
        }

        if preset.dcBlock == true {
            stages.append(DCBlockStage())
        }

        if let reverb = preset.reverb, reverb.mix > 0 {
            stages.append(ReverbStage(feedback: reverb.feedback,
                                      lowpassHz: reverb.lowpassHz,
                                      mix: reverb.mix))
        }

        if let hz = preset.lowpassHz, hz > 0 {
            stages.append(ButterworthStage(kind: .lowpass, frequency: hz))
        }

        if let limiter = preset.limiter {
            stages.append(LimiterStage(ceiling: limiter.ceiling,
                                       releaseSeconds: limiter.releaseSeconds))
        }

        return FXChain(stages: stages)
    }
}
