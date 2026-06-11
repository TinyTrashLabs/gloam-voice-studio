import Foundation
import MLXAudioCore

/// Thin wrapper so callers don't import MLXAudioCore for file output.
public enum WAVWriter {
    public static func write(samples: [Float], sampleRate: Int, to url: URL) throws {
        try AudioUtils.writeWavFile(samples: samples, sampleRate: sampleRate, fileURL: url)
    }
}
