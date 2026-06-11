import Foundation

/// Float waveform -> 16-bit LE mono PCM. Parity with the Python engine's
/// audio.py: clip to [-1, 1], scale by 32767, truncate toward zero.
public enum PCM16 {
    public static func data(from samples: [Float]) -> Data {
        var out = Data(capacity: samples.count * 2)
        for s in samples {
            let v = Int16(max(-1.0, min(1.0, s)) * 32767.0)  // Int16.init truncates toward zero
            out.append(v.leData)
        }
        return out
    }
}

public enum WAVEncoder {
    public static let provenanceComment = "Generated with Gloam Voice Studio"

    /// 16-bit PCM WAV. Byte-identical to the Python engine's pcm16_to_wav_bytes
    /// when provenance is nil; with provenance, a LIST/INFO/ICMT chunk follows
    /// the data chunk and the RIFF size accounts for it.
    public static func encode(pcm16: Data, sampleRate: Int, channels: Int = 1,
                              provenance: String? = nil) -> Data {
        var list = Data()
        if let provenance {
            var comment = Data(provenance.utf8)
            comment.append(0)                                  // null terminator
            if comment.count % 2 == 1 { comment.append(0) }    // word-align
            var info = Data("INFO".utf8)
            info.append(Data("ICMT".utf8))
            info.append(UInt32(comment.count).leData)
            info.append(comment)
            list.append(Data("LIST".utf8))
            list.append(UInt32(info.count).leData)
            list.append(info)
        }
        var out = Data()
        out.append(Data("RIFF".utf8))
        out.append(UInt32(36 + pcm16.count + list.count).leData)
        out.append(Data("WAVE".utf8))
        out.append(Data("fmt ".utf8))
        out.append(UInt32(16).leData)
        out.append(UInt16(1).leData)
        out.append(UInt16(channels).leData)
        out.append(UInt32(sampleRate).leData)
        out.append(UInt32(sampleRate * channels * 2).leData)
        out.append(UInt16(channels * 2).leData)
        out.append(UInt16(16).leData)
        out.append(Data("data".utf8))
        out.append(UInt32(pcm16.count).leData)
        out.append(pcm16)
        out.append(list)
        return out
    }
}

extension UInt32 { var leData: Data { withUnsafeBytes(of: littleEndian) { Data($0) } } }
extension UInt16 { var leData: Data { withUnsafeBytes(of: littleEndian) { Data($0) } } }
extension Int16 { var leData: Data { withUnsafeBytes(of: littleEndian) { Data($0) } } }
