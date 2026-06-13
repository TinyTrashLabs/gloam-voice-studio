import AVFoundation
import Foundation
import StudioKit

/// Converts an audio file (e.g. MP3) to canonical 16-bit PCM WAV bytes
/// suitable for storing as a voice reference clip.
enum AudioImport {
    /// Open the file at `url` with AVFoundation, read all samples, downmix to
    /// mono Float, then encode as a 16-bit LE WAV using StudioKit's WAVEncoder.
    /// Returns nil on any failure (bad format, read error, etc.).
    static func wavData(fromFileAt url: URL) -> Data? {
        guard let audioFile = try? AVAudioFile(forReading: url) else { return nil }
        let format = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }
        do {
            try audioFile.read(into: buffer)
        } catch {
            return nil
        }
        guard let channelData = buffer.floatChannelData else { return nil }
        let channelCount = Int(format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return nil }

        // Downmix to mono by averaging all channels.
        var mono = [Float](repeating: 0, count: frameLength)
        for ch in 0..<channelCount {
            let ptr = channelData[ch]
            for i in 0..<frameLength {
                mono[i] += ptr[i]
            }
        }
        if channelCount > 1 {
            let scale = 1.0 / Float(channelCount)
            for i in 0..<frameLength { mono[i] *= scale }
        }

        let sampleRate = Int(format.sampleRate)
        let pcm = PCM16.data(from: mono)
        return WAVEncoder.encode(pcm16: pcm, sampleRate: sampleRate)
    }
}
