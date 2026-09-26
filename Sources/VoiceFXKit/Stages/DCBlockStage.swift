//  DCBlockStage.swift
//
//  Swift port of Soundpipe's `dcblock` module.
//  Original: Soundpipe (https://github.com/PaulBatchelor/Soundpipe),
//  MIT License, Copyright (c) 2020 Paul Batchelor.
//  Extracted from Csound's "dcblock" opcode, original author Perry R. Cook (1995).

import Foundation

/// Removes DC offset. Belongs after any asymmetric waveshaper, whose output
/// carries an offset that would otherwise eat reverb and limiter headroom.
public final class DCBlockStage: FXStage {
    private let gain: Double
    private var lastInput = 0.0
    private var lastOutput = 0.0

    public init(gain: Double = 0.99) {
        // Soundpipe rejects degenerate gains and falls back to 0.99.
        self.gain = (gain == 0.0 || gain >= 1.0 || gain <= -1.0) ? 0.99 : gain
    }

    public func prepare(sampleRate: Double, maxBlock: Int) { reset() }

    public func process(_ input: UnsafePointer<Float>,
                        _ output: UnsafeMutablePointer<Float>,
                        frames: Int) {
        var inPrev = lastInput, outPrev = lastOutput
        for i in 0..<frames {
            let sample = Double(input[i])
            outPrev = sample - inPrev + gain * outPrev
            inPrev = sample
            output[i] = Float(outPrev)
        }
        lastInput = inPrev
        lastOutput = outPrev
    }

    public func reset() {
        lastInput = 0
        lastOutput = 0
    }
}
