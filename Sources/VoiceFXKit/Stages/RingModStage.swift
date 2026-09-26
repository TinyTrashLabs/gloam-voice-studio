//  RingModStage.swift
//
//  Ours. A ring modulator is a multiplication against a sine carrier; the
//  character comes from the mix and the carrier frequency, not the algorithm.

import Foundation

/// Multiplies the signal by a sine carrier. Low frequencies read as a growl;
/// higher ones as metallic, corrupted-toy artefacts.
public final class RingModStage: FXStage {
    private let frequency: Double
    private let mix: Float
    private var phase = 0.0
    private var phaseIncrement = 0.0

    /// - Parameter mix: 0 = dry (bypass), 1 = fully modulated.
    public init(frequency: Double, mix: Float = 1.0) {
        self.frequency = frequency
        self.mix = max(0, min(1, mix))
    }

    public func prepare(sampleRate: Double, maxBlock: Int) {
        phaseIncrement = 2.0 * Double.pi * frequency / sampleRate
        reset()
    }

    public func process(_ input: UnsafePointer<Float>,
                        _ output: UnsafeMutablePointer<Float>,
                        frames: Int) {
        var p = phase
        for i in 0..<frames {
            let carrier = Float(sin(p))
            let dry = input[i]
            output[i] = dry * (1 - mix) + dry * carrier * mix
            p += phaseIncrement
            // Wrap to keep precision stable over long utterances.
            if p > 2 * Double.pi { p -= 2 * Double.pi }
        }
        phase = p
    }

    public func reset() { phase = 0 }
}
