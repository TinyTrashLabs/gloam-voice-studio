import Foundation

/// The reference-audio loudness standard, applied where a voice's `ref.wav`
/// enters the library (#voice-loudness, 2026-08-29).
///
/// WHY HERE. A clone is exactly as loud as the reference it was cloned from,
/// and nothing downstream re-levels it — the iOS voice path is a plain gain
/// multiply with no compressor, so a quiet reference is quiet on every device
/// at every setting. Normalising at EXPORT would fix the shared .gvoice while
/// leaving the voice quiet in the app that made it; normalising at RENDER would
/// re-measure the same asset on every line. The library write is the one
/// boundary every voice crosses exactly once, however it arrived — recorded,
/// combined, or imported from someone else's pack.
///
/// The asset is otherwise untouched: this scales sample amplitudes inside the
/// existing `data` chunk and leaves the header, sample rate, channel count and
/// every other chunk exactly as they were. A reference is training material for
/// a cloning backend, so resampling or re-containering it to change its volume
/// would be a far larger change than the problem asks for.
public enum RefLoudness {
    /// Normalise a 16-bit PCM WAV to the reference standard. Returns the input
    /// unchanged — never throws — when the bytes are not a shape we recognise:
    /// a reference that cannot be levelled is still a usable reference, and
    /// refusing to save it would be a worse failure than saving it quiet.
    public static func normalized(wav: Data,
                                  targetDbFS: Float = AudioAssembler.referenceLoudnessDbFS,
                                  peakCeilingDbFS: Float = AudioAssembler.referencePeakCeilingDbFS) -> Data {
        guard let chunk = dataChunk(in: wav) else { return wav }
        let bytesPerSample = chunk.format == .pcm16 ? 2 : 4
        let count = chunk.length / bytesPerSample
        guard count > 0 else { return wav }

        var samples = [Float](repeating: 0, count: count)
        wav.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: chunk.offset)
            switch chunk.format {
            case .pcm16:
                for i in 0..<count {
                    let lo = UInt16(base.load(fromByteOffset: i * 2, as: UInt8.self))
                    let hi = UInt16(base.load(fromByteOffset: i * 2 + 1, as: UInt8.self))
                    samples[i] = Float(Int16(bitPattern: lo | (hi << 8))) / 32768
                }
            case .float32:
                for i in 0..<count {
                    var bits: UInt32 = 0
                    for b in 0..<4 {
                        bits |= UInt32(base.load(fromByteOffset: i * 4 + b, as: UInt8.self)) << (8 * UInt32(b))
                    }
                    samples[i] = Float(bitPattern: bits)
                }
            }
        }

        let gain = AudioAssembler.loudnessGain(floats: samples,
                                               targetDbFS: targetDbFS,
                                               peakCeilingDbFS: peakCeilingDbFS)
        // A gain this close to unity is below the threshold of audibility and
        // rewriting the bytes for it only churns the file.
        guard abs(gain - 1) > 0.01 else { return wav }

        var out = wav
        out.withUnsafeMutableBytes { raw in
            let base = raw.baseAddress!.advanced(by: chunk.offset)
            switch chunk.format {
            case .pcm16:
                for i in 0..<count {
                    let v = Int16(max(-1, min(1, samples[i] * gain)) * 32767)
                    let u = UInt16(bitPattern: v)
                    base.storeBytes(of: UInt8(u & 0xFF), toByteOffset: i * 2, as: UInt8.self)
                    base.storeBytes(of: UInt8(u >> 8), toByteOffset: i * 2 + 1, as: UInt8.self)
                }
            case .float32:
                for i in 0..<count {
                    // Float WAV is not bound to [-1, 1] by the format, but every
                    // consumer here treats it as full scale — clamp for the same
                    // reason the PCM path does.
                    let bits = max(-1, min(1, samples[i] * gain)).bitPattern
                    for b in 0..<4 {
                        base.storeBytes(of: UInt8((bits >> (8 * UInt32(b))) & 0xFF),
                                        toByteOffset: i * 4 + b, as: UInt8.self)
                    }
                }
            }
        }
        return out
    }

    /// Sample format of a `data` chunk this scaler understands.
    enum SampleFormat: Equatable {
        /// WAVE_FORMAT_PCM, 16-bit signed little-endian.
        case pcm16
        /// WAVE_FORMAT_IEEE_FLOAT, 32-bit little-endian. The LuxTTS lane writes
        /// its derived reference window in this format (engines/lux-tts/ref.wav),
        /// and that is the file the engine actually renders from — so a standard
        /// that only understood PCM16 would silently skip exactly the asset that
        /// matters for a cloned voice.
        case float32
    }

    /// Byte range of the `data` chunk and its format.
    /// Walks the RIFF chunk list rather than assuming a 44-byte header: a WAV
    /// may legally carry LIST/fact/cue chunks before `data`, and an offset
    /// guessed from the canonical layout would scale header bytes as if they
    /// were audio.
    static func dataChunk(in wav: Data) -> (offset: Int, length: Int, format: SampleFormat)? {
        guard wav.count >= 12,
              wav[wav.startIndex ..< wav.startIndex + 4].elementsEqual(Array("RIFF".utf8)),
              wav[wav.startIndex + 8 ..< wav.startIndex + 12].elementsEqual(Array("WAVE".utf8))
        else { return nil }

        func u16(_ at: Int) -> Int { Int(wav[at]) | (Int(wav[at + 1]) << 8) }
        func u32(_ at: Int) -> Int {
            Int(wav[at]) | (Int(wav[at + 1]) << 8) | (Int(wav[at + 2]) << 16) | (Int(wav[at + 3]) << 24)
        }

        var bitsPerSample = 0
        var formatTag = 0
        var i = wav.startIndex + 12
        while i + 8 <= wav.endIndex {
            let id = String(decoding: wav[i ..< i + 4], as: UTF8.self)
            let size = u32(i + 4)
            let body = i + 8
            guard size >= 0, body + size <= wav.endIndex else { return nil }
            if id == "fmt " , size >= 16 {
                formatTag = u16(body)
                bitsPerSample = u16(body + 14)
            } else if id == "data" {
                // 1 == WAVE_FORMAT_PCM, 3 == WAVE_FORMAT_IEEE_FLOAT. Anything else
                // (ADPCM, extensible) is not what this scaler assumes, so leave it.
                if formatTag == 1, bitsPerSample == 16 { return (body, size, .pcm16) }
                if formatTag == 3, bitsPerSample == 32 { return (body, size, .float32) }
                return nil
            }
            i = body + size + (size % 2)   // chunks are word-aligned
        }
        return nil
    }

    /// Back-compat: the PCM16 range only. Kept because the shape of a 16-bit
    /// reference is what most callers reason about.
    static func pcm16DataChunk(in wav: Data) -> (offset: Int, length: Int)? {
        guard let c = dataChunk(in: wav), c.format == .pcm16 else { return nil }
        return (c.offset, c.length)
    }
}
