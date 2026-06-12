import AVFAudio
import Foundation

/// A Sendable slice of mono audio. AVAudioPCMBuffer is not Sendable, so the
/// capture side converts buffers to plain samples and transcribers convert
/// back as needed.
public struct AudioChunk: Equatable, Sendable {
    public let samples: [Float]
    public let sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    /// Rebuild a float32 mono AVAudioPCMBuffer (for SFSpeech append()).
    public func pcmBuffer() -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                  channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!,
                                               count: samples.count)
        }
        return buffer
    }
}
