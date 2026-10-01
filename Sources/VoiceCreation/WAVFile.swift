import Foundation

/// 16-bit PCM mono RIFF/WAVE bytes — byte-identical to StudioKit's
/// `WAVEncoder.encode(pcm16: PCM16.data(from:), …)` without provenance.
/// Kept here because VoiceCreation can't depend on StudioKit (StudioKit
/// depends on it).
public enum WAVFile {
    public static func encode(mono samples: [Float], sampleRate: Int) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            let v = Int16(max(-1.0, min(1.0, s)) * 32767.0)   // truncates toward zero, like PCM16
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var out = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        out.append(Data("RIFF".utf8)); u32(UInt32(36 + pcm.count)); out.append(Data("WAVE".utf8))
        out.append(Data("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        out.append(Data("data".utf8)); u32(UInt32(pcm.count)); out.append(pcm)
        return out
    }
}
