import Foundation

/// The simplest possible stage. Exists so chain composition, buffer hand-off
/// and the chunk-invariance harness can be tested before any real DSP lands.
public final class GainStage: FXStage {
    private let gain: Float

    public init(gain: Float) { self.gain = gain }

    public func prepare(sampleRate: Double, maxBlock: Int) {}

    public func process(_ input: UnsafePointer<Float>,
                        _ output: UnsafeMutablePointer<Float>,
                        frames: Int) {
        for i in 0..<frames { output[i] = input[i] * gain }
    }

    public func reset() {}
}
