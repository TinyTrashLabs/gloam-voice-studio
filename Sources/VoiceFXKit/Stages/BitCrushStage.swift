//  BitCrushStage.swift
//
//  Swift port of Soundpipe's `bitcrush` module, with its `fold` dependency
//  inlined (Soundpipe's bitcrush drives an sp_fold to hold samples).
//  Original: Soundpipe (https://github.com/PaulBatchelor/Soundpipe),
//  MIT License, Copyright (c) 2020 Paul Batchelor.
//  `fold` extracted from Csound's "fold" opcode, original authors
//  John FFitch and Gabriel Maldonado (1998).

import Foundation

/// Amplitude quantisation plus sample-rate reduction — the "cursed toy" sound.
public final class BitCrushStage: FXStage {
    private let bitDepth: Double
    private let targetRate: Double
    private var sampleRate = 48_000.0
    private var foldIncrement = 1.0

    // Soundpipe's sp_fold state: a sample-and-hold driven by a fractional index.
    private var foldIndex = 0.0
    private var foldSampleIndex: Int32 = 0
    private var foldValue = 0.0

    public init(bitDepth: Double = 8, targetRate: Double = 10_000) {
        self.bitDepth = bitDepth
        self.targetRate = targetRate
    }

    public func prepare(sampleRate: Double, maxBlock: Int) {
        self.sampleRate = sampleRate
        // Soundpipe recomputes this per sample from sp->sr / p->srate; both are
        // constant for us, so it is hoisted here.
        self.foldIncrement = sampleRate / targetRate
        reset()
    }

    public func process(_ input: UnsafePointer<Float>,
                        _ output: UnsafeMutablePointer<Float>,
                        frames: Int) {
        let bits = pow(2, floor(bitDepth))
        var index = foldIndex
        var sampleIndex = foldSampleIndex
        var held = foldValue

        for i in 0..<frames {
            // Quantise through a 16-bit-shaped grid, exactly as Soundpipe does.
            var v = Double(input[i]) * 65536.0
            v += 32768
            v *= (bits / 65536.0)
            v = floor(v)
            v = v * (65536.0 / bits) - 32768

            // sp_fold: hold `held` until the fractional index catches up.
            if index < Double(sampleIndex) {
                index += foldIncrement
                held = v
            }
            sampleIndex &+= 1
            output[i] = Float(held / 65536.0)
        }

        foldIndex = index
        foldSampleIndex = sampleIndex
        foldValue = held
    }

    public func reset() {
        foldIndex = 0
        foldSampleIndex = 0
        foldValue = 0
    }
}
