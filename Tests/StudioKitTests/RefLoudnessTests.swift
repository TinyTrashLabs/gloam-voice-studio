import XCTest
@testable import StudioKit

/// The reference-audio loudness standard (#voice-loudness, 2026-08-29).
///
/// A clone is exactly as loud as the reference it was cloned from and nothing
/// downstream re-levels it — the iOS voice path is a plain gain multiply with no
/// compressor — so an under-level reference is quiet on every device at every
/// setting. These pin the standard itself, not a preference: the target is
/// measured from the bundled host whose level is known-good.
final class RefLoudnessTests: XCTestCase {

    /// 16-bit PCM WAV of a sine at a chosen amplitude — the shape the library
    /// actually stores.
    private func wav(amplitude: Float, seconds: Double = 1, rate: Int = 24_000) -> Data {
        let n = Int(Double(rate) * seconds)
        var pcm = Data(capacity: n * 2)
        for i in 0..<n {
            let s = amplitude * sin(2 * .pi * 220 * Float(i) / Float(rate))
            pcm.append(contentsOf: withUnsafeBytes(of: Int16(max(-1, min(1, s)) * 32767).littleEndian) { Array($0) })
        }
        return WAVEncoder.encode(pcm16: pcm, sampleRate: rate)
    }

    private func rmsDbFS(_ d: Data) -> Float {
        guard let c = RefLoudness.pcm16DataChunk(in: d) else { return .nan }
        let n = c.length / 2
        var sum = 0.0
        d.withUnsafeBytes { raw in
            let b = raw.baseAddress!.advanced(by: c.offset)
            for i in 0..<n {
                let lo = UInt16(b.load(fromByteOffset: i * 2, as: UInt8.self))
                let hi = UInt16(b.load(fromByteOffset: i * 2 + 1, as: UInt8.self))
                let v = Double(Int16(bitPattern: lo | (hi << 8))) / 32768
                sum += v * v
            }
        }
        return Float(20 * log10((sum / Double(n)).squareRoot()))
    }

    private func peakDbFS(_ d: Data) -> Float {
        guard let c = RefLoudness.pcm16DataChunk(in: d) else { return .nan }
        var peak = 0.0
        d.withUnsafeBytes { raw in
            let b = raw.baseAddress!.advanced(by: c.offset)
            for i in 0..<(c.length / 2) {
                let lo = UInt16(b.load(fromByteOffset: i * 2, as: UInt8.self))
                let hi = UInt16(b.load(fromByteOffset: i * 2 + 1, as: UInt8.self))
                peak = max(peak, abs(Double(Int16(bitPattern: lo | (hi << 8))) / 32768))
            }
        }
        return Float(20 * log10(peak))
    }

    /// THE bug: an imported voice sat ~2.3 dB under the shipped hosts and was
    /// audibly quieter on an iPhone at the same gain.
    func testQuietReferenceIsBroughtUpToTheStandard() {
        // A sine's RMS sits only 3 dB under its peak, so "quiet" here means a
        // much smaller amplitude than a speech waveform would need: 0.08 peak is
        // about -24.9 dBFS RMS, comfortably under the standard.
        let quiet = wav(amplitude: 0.08)
        XCTAssertLessThan(rmsDbFS(quiet), AudioAssembler.referenceLoudnessDbFS - 2)
        let fixed = RefLoudness.normalized(wav: quiet)
        XCTAssertEqual(rmsDbFS(fixed), AudioAssembler.referenceLoudnessDbFS, accuracy: 0.5)
    }

    /// Normalising is a two-way standard, not a boost: a hot reference comes DOWN.
    func testHotReferenceIsBroughtDownToTheStandard() {
        let loud = wav(amplitude: 0.95)
        XCTAssertGreaterThan(rmsDbFS(loud), AudioAssembler.referenceLoudnessDbFS + 2)
        XCTAssertEqual(rmsDbFS(RefLoudness.normalized(wav: loud)),
                       AudioAssembler.referenceLoudnessDbFS, accuracy: 0.5)
    }

    /// The whole point: two references that started far apart end up matched, so
    /// "gain 1" means the same thing for every voice.
    func testTwoVoicesEndUpAtTheSameLevel() {
        let a = rmsDbFS(RefLoudness.normalized(wav: wav(amplitude: 0.08)))
        let b = rmsDbFS(RefLoudness.normalized(wav: wav(amplitude: 0.90)))
        XCTAssertEqual(a, b, accuracy: 0.5)
    }

    /// A quiet-but-spiky clip must not be boosted into clipping — the ceiling
    /// binds and we accept being under target rather than distort.
    func testPeakCeilingWinsOverTheRmsTarget() {
        // Mostly silence with one full-scale spike: very low RMS, peak already at FS.
        var pcm = Data(count: 24_000 * 2)
        pcm.replaceSubrange(0..<2, with: withUnsafeBytes(of: Int16(32767).littleEndian) { Array($0) })
        let spiky = WAVEncoder.encode(pcm16: pcm, sampleRate: 24_000)
        let out = RefLoudness.normalized(wav: spiky)
        XCTAssertLessThanOrEqual(peakDbFS(out), AudioAssembler.referencePeakCeilingDbFS + 0.5)
    }

    /// Format is training material for a cloning backend — only amplitude may
    /// change. Same byte count, same header, same sample rate.
    func testHeaderAndSampleRateSurviveUntouched() {
        let original = wav(amplitude: 0.2, rate: 44_100)
        let out = RefLoudness.normalized(wav: original)
        XCTAssertEqual(out.count, original.count)
        XCTAssertEqual(out.prefix(44), original.prefix(44))
    }

    /// Digital silence has no loudness to correct; any finite gain leaves it silent.
    func testSilenceIsLeftAlone() {
        let silence = WAVEncoder.encode(pcm16: Data(count: 4_800), sampleRate: 24_000)
        XCTAssertEqual(RefLoudness.normalized(wav: silence), silence)
    }

    /// Unparseable or non-PCM16 bytes are returned untouched rather than mangled:
    /// a reference that cannot be levelled is still a usable reference.
    func testUnrecognisedBytesPassThrough() {
        let junk = Data("not a wav at all".utf8)
        XCTAssertEqual(RefLoudness.normalized(wav: junk), junk)
    }

    /// The data chunk is found by walking RIFF, not by assuming a 44-byte header:
    /// a LIST chunk before `data` would otherwise put the scaler on header bytes.
    func testFindsDataChunkPastAnExtraChunk() {
        let base = wav(amplitude: 0.3)
        guard let chunk = RefLoudness.pcm16DataChunk(in: base) else { return XCTFail("no chunk") }
        var spliced = base.prefix(chunk.offset - 8)
        spliced.append(contentsOf: Array("LIST".utf8))
        spliced.append(contentsOf: withUnsafeBytes(of: UInt32(4).littleEndian) { Array($0) })
        spliced.append(contentsOf: Array("INFO".utf8))
        spliced.append(base.suffix(from: chunk.offset - 8))
        let found = RefLoudness.pcm16DataChunk(in: spliced)
        XCTAssertEqual(found?.length, chunk.length)
        XCTAssertEqual(found?.offset, chunk.offset + 12)
    }
}
