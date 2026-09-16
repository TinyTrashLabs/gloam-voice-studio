//  ReverbStage.swift
//
//  Swift port of Soundpipe's `revsc` module.
//  Original: Soundpipe (https://github.com/PaulBatchelor/Soundpipe),
//  MIT License, Copyright (c) 2020 Paul Batchelor.
//  Extracted from Csound's "reverbsc" opcode, original authors
//  Sean Costello and Istvan Varga (1999, 2005).
//
//  Mono adaptation: the original is stereo. Here one input feeds both sides
//  and the two outputs are averaged. The eight delay lines are kept (rather
//  than halved) because their mutual decorrelation is what keeps the tail
//  from sounding like a comb filter.

import Foundation

public final class ReverbStage: FXStage {
    // Delay time (s), random delay variation (s), variation frequency (1/s),
    // random seed. Verbatim from Soundpipe's reverbParams table; the delay
    // times are expressed against its 44100 reference rate.
    private static let defaultSampleRate = 44_100.0
    private static let params: [(delay: Double, variation: Double, frequency: Double, seed: Double)] = [
        (2473.0 / defaultSampleRate, 0.0010, 3.100,  1966.0),
        (2767.0 / defaultSampleRate, 0.0011, 3.500, 29491.0),
        (3217.0 / defaultSampleRate, 0.0017, 1.110, 22937.0),
        (3557.0 / defaultSampleRate, 0.0006, 3.973,  9830.0),
        (3907.0 / defaultSampleRate, 0.0010, 2.341, 20643.0),
        (4127.0 / defaultSampleRate, 0.0011, 1.897, 22937.0),
        (2143.0 / defaultSampleRate, 0.0017, 0.891, 29491.0),
        (1933.0 / defaultSampleRate, 0.0006, 3.221, 14417.0),
    ]
    private static let outputGain = 0.35
    private static let junctionScale = 0.25
    private static let delayPositionShift = 28
    private static let delayPositionScale = 0x1000_0000
    private static let delayPositionMask = 0x0FFF_FFFF

    private final class DelayLine {
        var buffer: [Double] = []
        var bufferSize = 0
        var writePos = 0
        var readPos = 0
        var readPosFrac = 0
        var readPosFracIncrement = 0
        var randLineCount = 0
        var filterState = 0.0
        var seed = 0
    }

    private let feedback: Double
    private let lowpassHz: Double
    private let mix: Float
    private var sampleRate = 48_000.0
    private var dampFactor = 1.0
    private var lines: [DelayLine] = (0..<8).map { _ in DelayLine() }

    /// - Parameters:
    ///   - feedback: 0–1. Higher rings longer. Soundpipe's default is 0.97.
    ///   - lowpassHz: damping corner inside each feedback path.
    ///   - mix: 0 = dry, 1 = fully wet.
    public init(feedback: Double = 0.97, lowpassHz: Double = 10_000, mix: Float = 1.0) {
        self.feedback = feedback
        self.lowpassHz = lowpassHz
        self.mix = max(0, min(1, mix))
    }

    public func prepare(sampleRate: Double, maxBlock: Int) {
        self.sampleRate = sampleRate
        // Damping coefficient, derived once because lowpassHz is constant here
        // (Soundpipe recomputes it whenever its lpfreq changes).
        var d = 2.0 - cos(lowpassHz * (2 * Double.pi) / sampleRate)
        d = d - (d * d - 1.0).squareRoot()
        dampFactor = d
        for (n, line) in lines.enumerated() {
            line.bufferSize = Self.maxSamples(sampleRate: sampleRate, index: n)
            line.buffer = [Double](repeating: 0, count: line.bufferSize)
            initialiseDelayLine(line, index: n)
        }
    }

    public func reset() {
        for (n, line) in lines.enumerated() {
            for i in 0..<line.buffer.count { line.buffer[i] = 0 }
            initialiseDelayLine(line, index: n)
        }
    }

    private static func maxSamples(sampleRate: Double, index n: Int) -> Int {
        let p = params[n]
        let maxDelay = p.delay + p.variation * 1.0 * 1.125
        return Int(maxDelay * sampleRate + 16.5)
    }

    private func initialiseDelayLine(_ line: DelayLine, index n: Int) {
        let p = Self.params[n]
        line.writePos = 0
        line.seed = Int(p.seed + 0.5)
        var readPos = Double(line.seed) * p.variation / 32768.0
        readPos = p.delay + readPos
        readPos = Double(line.bufferSize) - (readPos * sampleRate)
        line.readPos = Int(readPos)
        line.readPosFrac = Int((readPos - Double(line.readPos)) * Double(Self.delayPositionScale) + 0.5)
        line.filterState = 0.0
        nextRandomLineSegment(line, index: n)
    }

    private func nextRandomLineSegment(_ line: DelayLine, index n: Int) {
        let p = Self.params[n]
        // 16-bit LCG, exactly as in the original.
        if line.seed < 0 { line.seed += 0x10000 }
        line.seed = (line.seed &* 15625 &+ 1) & 0xFFFF
        if line.seed >= 0x8000 { line.seed -= 0x10000 }

        line.randLineCount = Int((sampleRate / p.frequency) + 0.5)
        var previousDelay = Double(line.writePos)
        previousDelay -= Double(line.readPos)
            + Double(line.readPosFrac) / Double(Self.delayPositionScale)
        while previousDelay < 0 { previousDelay += Double(line.bufferSize) }
        previousDelay /= sampleRate

        var nextDelay = Double(line.seed) * p.variation / 32768.0
        nextDelay = p.delay + nextDelay
        var increment = (previousDelay - nextDelay) / Double(line.randLineCount)
        increment = increment * sampleRate + 1.0
        line.readPosFracIncrement = Int(increment * Double(Self.delayPositionScale) + 0.5)
    }

    public func process(_ input: UnsafePointer<Float>,
                        _ output: UnsafeMutablePointer<Float>,
                        frames: Int) {
        guard mix > 0 else {
            for i in 0..<frames { output[i] = input[i] }
            return
        }
        for frame in 0..<frames {
            let dry = Double(input[frame])

            // "Resultant junction pressure": every line's damped state, summed
            // and scaled, mixed back into the inputs.
            var junction = 0.0
            for line in lines { junction += line.filterState }
            junction *= Self.junctionScale
            let inL = junction + dry
            let inR = junction + dry

            var outL = 0.0, outR = 0.0

            for n in 0..<8 {
                let line = lines[n]
                let bufferSize = line.bufferSize

                line.buffer[line.writePos] = (n & 1 == 1 ? inR : inL) - line.filterState
                line.writePos += 1
                if line.writePos >= bufferSize { line.writePos -= bufferSize }

                if line.readPosFrac >= Self.delayPositionScale {
                    line.readPos += line.readPosFrac >> Self.delayPositionShift
                    line.readPosFrac &= Self.delayPositionMask
                }
                if line.readPos >= bufferSize { line.readPos -= bufferSize }
                var readPos = line.readPos
                let frac = Double(line.readPosFrac) * (1.0 / Double(Self.delayPositionScale))

                // Cubic interpolation coefficients, verbatim from the original.
                var a2 = frac * frac; a2 -= 1.0; a2 *= (1.0 / 6.0)
                var a1 = frac; a1 += 1.0; a1 *= 0.5
                var am1 = a1 - 1.0
                var a0 = 3.0 * a2
                a1 -= a0; am1 -= a2; a0 -= frac

                let vm1: Double, v1: Double, v2: Double
                var v0: Double
                if readPos > 0 && readPos < (bufferSize - 2) {
                    vm1 = line.buffer[readPos - 1]
                    v0  = line.buffer[readPos]
                    v1  = line.buffer[readPos + 1]
                    v2  = line.buffer[readPos + 2]
                } else {
                    readPos -= 1; if readPos < 0 { readPos += bufferSize }
                    vm1 = line.buffer[readPos]
                    readPos += 1; if readPos >= bufferSize { readPos -= bufferSize }
                    v0 = line.buffer[readPos]
                    readPos += 1; if readPos >= bufferSize { readPos -= bufferSize }
                    v1 = line.buffer[readPos]
                    readPos += 1; if readPos >= bufferSize { readPos -= bufferSize }
                    v2 = line.buffer[readPos]
                }
                v0 = (am1 * vm1 + a0 * v0 + a1 * v1 + a2 * v2) * frac + v0

                line.readPosFrac += line.readPosFracIncrement

                v0 *= feedback
                v0 = (line.filterState - v0) * dampFactor + v0
                line.filterState = v0

                if n & 1 == 1 { outR += v0 } else { outL += v0 }

                line.randLineCount -= 1
                if line.randLineCount <= 0 { nextRandomLineSegment(line, index: n) }
            }

            // Mono fold-down of the stereo pair.
            let wet = ((outL + outR) * 0.5) * Self.outputGain
            let value = Double(1 - mix) * dry + Double(mix) * wet
            output[frame] = value.isFinite ? Float(value) : 0
        }
    }
}
