//  ParallelMixStage.swift
//
//  Ours. Runs a branch alongside the dry path and sums them.

import Foundation

/// Splits one input across two paths and sums them.
///
/// BOTH paths see the same input. That is the whole point: in the demon preset
/// the two paths are `PitchFormantStage`s at different transpositions, giving
/// one voice with two vocal tracts slightly disagreeing. If the branch were fed
/// the primary's OUTPUT instead, the two shifts would compose into a single
/// deeper shift and the doubling — most of the character — would vanish.
public final class ParallelMixStage: FXStage {
    private let primary: FXStage?
    private let branch: FXStage
    private let primaryGain: Float
    private let branchGain: Float
    private var primaryBuffer: [Float] = []
    private var branchBuffer: [Float] = []
    private var maxBlock = 0

    /// - Parameter primary: the main path. nil means a dry pass-through.
    public init(primary: FXStage?, branch: FXStage,
                primaryGain: Float = 1.0, branchGain: Float = 0.5) {
        self.primary = primary
        self.branch = branch
        self.primaryGain = primaryGain
        self.branchGain = branchGain
    }

    /// The longer of the two paths — they run on the same input, not in series.
    public var latencyFrames: Int { max(primary?.latencyFrames ?? 0, branch.latencyFrames) }

    public func prepare(sampleRate: Double, maxBlock: Int) {
        self.maxBlock = maxBlock
        primaryBuffer = [Float](repeating: 0, count: maxBlock)
        branchBuffer = [Float](repeating: 0, count: maxBlock)
        primary?.prepare(sampleRate: sampleRate, maxBlock: maxBlock)
        branch.prepare(sampleRate: sampleRate, maxBlock: maxBlock)
    }

    public func process(_ input: UnsafePointer<Float>,
                        _ output: UnsafeMutablePointer<Float>,
                        frames: Int) {
        precondition(frames <= maxBlock, "frames exceeds maxBlock; call prepare with a larger maxBlock")
        primaryBuffer.withUnsafeMutableBufferPointer { p in
            branchBuffer.withUnsafeMutableBufferPointer { b in
                if let primary {
                    primary.process(input, p.baseAddress!, frames: frames)
                } else {
                    p.baseAddress!.update(from: input, count: frames)
                }
                // Note `input`, not p — both paths read the original signal.
                branch.process(input, b.baseAddress!, frames: frames)
                for i in 0..<frames {
                    output[i] = p[i] * primaryGain + b[i] * branchGain
                }
            }
        }
    }

    public func reset() {
        primary?.reset()
        branch.reset()
        for i in 0..<primaryBuffer.count { primaryBuffer[i] = 0 }
        for i in 0..<branchBuffer.count { branchBuffer[i] = 0 }
    }
}
