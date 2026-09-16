//  ButterworthStage.swift
//
//  Swift port of Soundpipe's `butlp` and `buthp` modules — a 2nd-order
//  Butterworth filter discretised with the bilinear transform.
//  See https://ccrma.stanford.edu/~jos/filters/Example_Second_Order_Butterworth_Lowpass.html
//
//  Original: Soundpipe (https://github.com/PaulBatchelor/Soundpipe),
//  MIT License, Copyright (c) 2020 Paul Batchelor.
//  Soundpipe's butlp/buthp derive from Csound's Butterworth opcodes.

import Foundation

public final class ButterworthStage: FXStage {
    public enum Kind: String, Codable, Sendable { case lowpass, highpass }

    private let kind: Kind
    private let frequency: Double
    /// Biquad coefficients a0...a4, matching Soundpipe's `a[0..4]` exactly.
    private var a = [Double](repeating: 0, count: 5)
    /// t(n-1) and t(n-2) — Soundpipe keeps these in a[5] and a[6].
    private var t1 = 0.0
    private var t2 = 0.0

    public init(kind: Kind, frequency: Double) {
        self.kind = kind
        self.frequency = frequency
    }

    public func prepare(sampleRate: Double, maxBlock: Int) {
        reset()
        guard frequency > 0 else { return }
        let root2 = 1.414_213_562_373_095_048_8
        let pidsr = Double.pi / sampleRate
        // Lowpass uses cot(wc), highpass uses tan(wc); the rest is shared.
        let c = kind == .lowpass ? 1.0 / tan(pidsr * frequency) : tan(pidsr * frequency)
        a[0] = 1.0 / (1.0 + c * root2 + c * c)
        a[1] = kind == .lowpass ? 2 * a[0] : -2 * a[0]
        a[2] = a[0]
        a[3] = kind == .lowpass
            ? 2.0 * (1.0 - c * c) * a[0]
            : 2.0 * (c * c - 1.0) * a[0]
        a[4] = (1.0 - c * root2 + c * c) * a[0]
    }

    public func process(_ input: UnsafePointer<Float>,
                        _ output: UnsafeMutablePointer<Float>,
                        frames: Int) {
        guard frequency > 0 else {
            for i in 0..<frames { output[i] = 0 }
            return
        }
        let a0 = a[0], a1 = a[1], a2 = a[2], a3 = a[3], a4 = a[4]
        var s1 = t1, s2 = t2
        for i in 0..<frames {
            let t = Double(input[i]) - a3 * s1 - a4 * s2
            let y = t * a0 + a1 * s1 + a2 * s2
            s2 = s1
            s1 = t
            output[i] = Float(y)
        }
        t1 = s1
        t2 = s2
    }

    public func reset() {
        t1 = 0
        t2 = 0
    }
}
