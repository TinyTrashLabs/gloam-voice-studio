import AVFoundation
import Foundation

/// Audio file decoding the editor and the reference rules share.
public enum VoiceAudio {
    /// Load a mono clip resampled to 24 kHz float samples.
    /// `maxSeconds` bounds how much of the file is decoded, measured at the
    /// file's own rate: an hour-long import must not become an hour of floats
    /// in memory when the clone only ever keeps its first window.
    public static func loadWav24k(_ url: URL, maxSeconds: Double? = nil) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFmt = file.processingFormat
        var cap = AVAudioFrameCount(file.length)
        if let maxSeconds {
            cap = min(cap, AVAudioFrameCount(maxSeconds * inFmt.sampleRate))
        }
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: cap) else { return [] }
        try file.read(into: inBuf)
        // Convert to 24 kHz mono float.
        let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000,
                                   channels: 1, interleaved: false)!
        guard let conv = AVAudioConverter(from: inFmt, to: outFmt) else { return [] }
        let ratio = 24000.0 / inFmt.sampleRate
        let outCap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio + 1024)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap) else { return [] }
        var fed = false
        var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        if let err { throw err }
        let n = Int(outBuf.frameLength)
        return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: n))
    }

    /// The master's length from its header, no decode.
    public static func seconds(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
