//  DriveStage.swift
//
//  Swift port of Soundpipe's `dist` module.
//  Original: Soundpipe (https://github.com/PaulBatchelor/Soundpipe),
//  MIT License, Copyright (c) 2020 Paul Batchelor.
//  Extracted from Csound's "distort1" opcode, original author Hans Mikelson (1998).

import Foundation

/// Asymmetric tanh-style waveshaper. The growl in the demon preset.
/// Stateless per sample, but still an `FXStage` so it composes in the chain.
public final class DriveStage: FXStage {
    private let shapeA: Double
    private let shapeB: Double
    private let preGain: Double
    private let postGain: Double

    public init(preGain: Double = 2.0, postGain: Double = 0.5,
                shape1: Double = 0, shape2: Double = 0) {
        // Soundpipe applies these fixed scalings before use.
        let pre = preGain * 6.5536
        var post = postGain * 0.61035156
        let s1 = shape1 * 4.096 + pre
        let s2 = shape2 * 4.096 - pre
        post *= 0.5
        self.preGain = pre
        self.postGain = post
        self.shapeA = s1
        self.shapeB = s2
    }

    public func prepare(sampleRate: Double, maxBlock: Int) {}

    public func process(_ input: UnsafePointer<Float>,
                        _ output: UnsafeMutablePointer<Float>,
                        frames: Int) {
        for i in 0..<frames {
            let sig = Double(input[i])
            let y = ((exp(sig * shapeA) - exp(sig * shapeB)) / cosh(sig * preGain)) * postGain
            // cosh overflows to inf for large |sig*preGain|, yielding NaN.
            // A NaN entering the reverb would poison its delay lines forever.
            output[i] = y.isFinite ? Float(y) : 0
        }
    }

    public func reset() {}
}
