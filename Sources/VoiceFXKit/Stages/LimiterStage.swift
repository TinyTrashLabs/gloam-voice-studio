//  LimiterStage.swift
//
//  Ours. Soundpipe's compressor is Faust-generated and drags in CUI.h
//  scaffolding; a safety limiter does not justify that import.

import Foundation

/// Final-stage brickwall limiter. Not optional in any preset: the demon chain
/// adds substantial low-end energy and the playback target is a toy speaker.
///
/// Instantaneous attack, exponential release. Because attack is instantaneous
/// there is no lookahead and therefore no added latency — the trade is a
/// little harmonic distortion on transients, which suits the material.
public final class LimiterStage: FXStage {
    private let ceiling: Float
    private let releaseSeconds: Double
    private var releaseCoefficient: Float = 0
    private var gain: Float = 1

    public init(ceiling: Float = 0.95, releaseSeconds: Double = 0.05) {
        self.ceiling = ceiling
        self.releaseSeconds = releaseSeconds
    }

    public func prepare(sampleRate: Double, maxBlock: Int) {
        releaseCoefficient = Float(exp(-1.0 / (releaseSeconds * sampleRate)))
        reset()
    }

    public func process(_ input: UnsafePointer<Float>,
                        _ output: UnsafeMutablePointer<Float>,
                        frames: Int) {
        var g = gain
        for i in 0..<frames {
            let x = input[i]
            let magnitude = abs(x)
            // Gain needed to keep this sample under the ceiling.
            let required = magnitude > ceiling ? ceiling / magnitude : 1
            if required < g {
                g = required            // clamp immediately
            } else {
                g += (required - g) * (1 - releaseCoefficient)   // release slowly
            }
            output[i] = x * g
        }
        gain = g
    }

    public func reset() { gain = 1 }
}
