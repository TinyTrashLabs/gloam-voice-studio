import XCTest
import ZIPFoundation
@testable import StudioKit

/// The per-voice loudness trim.
///
/// The reference standard (`RefLoudnessTests`) makes every voice MEASURE the
/// same. This is the layer above it: two references at an identical -17.0 LUFS
/// can still sit differently in a mix, and that part is taste, not measurement.
/// These pin that the trim is a correction ON TOP of the standard — carried with
/// the voice, bounded, and applied to output rather than baked into a reference.
final class VoiceGainTests: XCTestCase {

    private func library() throws -> VoiceLibrary {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return VoiceLibrary(directory: dir)
    }

    private func wav(amplitude: Float, rate: Int = 24_000) -> Data {
        var pcm = Data()
        for i in 0 ..< rate {
            let s = amplitude * sin(2 * .pi * 220 * Float(i) / Float(rate))
            pcm.append(contentsOf: withUnsafeBytes(of: Int16(max(-1, min(1, s)) * 32767).littleEndian) { Array($0) })
        }
        return WAVEncoder.encode(pcm16: pcm, sampleRate: rate)
    }

    // MARK: - Storage

    func testGainRoundTripsThroughMetaAndDefaultsToUnset() throws {
        let lib = try library()
        let saved = try lib.save(name: "Trimmed", refWav: wav(amplitude: 0.3), refText: "hello")
        // Unset, NOT 0 — the distinction the field exists to preserve.
        XCTAssertNil(saved.gain)

        try lib.setGain(saved.slug, gainDb: -2.5)
        XCTAssertEqual(try lib.get(saved.slug).0.gain, -2.5)

        try lib.setGain(saved.slug, gainDb: nil)
        XCTAssertNil(try lib.get(saved.slug).0.gain)
    }

    /// A trim corrects a voice that already measures right, so a huge one means
    /// the reference is wrong. Unbounded, a slider could simply undo the standard.
    func testGainIsClampedOnTheWayIn() throws {
        let lib = try library()
        let saved = try lib.save(name: "Loud", refWav: wav(amplitude: 0.3), refText: "hi")
        try lib.setGain(saved.slug, gainDb: 99)
        XCTAssertEqual(try lib.get(saved.slug).0.gain, GVoice.maxGainDb)
        try lib.setGain(saved.slug, gainDb: -99)
        XCTAssertEqual(try lib.get(saved.slug).0.gain, -GVoice.maxGainDb)
    }

    /// A malformed value must not break voice load — the same tolerance every
    /// other optional field in meta.json gets.
    func testAMalformedGainDoesNotBreakLoad() throws {
        let json = Data(#"{"name":"X","slug":"x","gain":"loud"}"#.utf8)
        let meta = try JSONDecoder().decode(VoiceMeta.self, from: json)
        XCTAssertEqual(meta.name, "X")
        XCTAssertNil(meta.gain)
    }

    // MARK: - Resolution

    func testManifestGainResolvesAndClamps() {
        func manifest(_ g: Double?) -> GVoice.Manifest {
            GVoice.Manifest(gvoice: 2, name: "V", slug: "v", createdAt: nil,
                            variants: nil, pace: nil, enginePace: nil, gain: g,
                            source: nil, engines: nil, provenance: nil)
        }
        XCTAssertEqual(GVoice.gain(in: manifest(nil)), 0)
        XCTAssertEqual(GVoice.gain(in: manifest(-3)), -3)
        XCTAssertEqual(GVoice.gain(in: manifest(500)), GVoice.maxGainDb)
        // A hand-edited manifest can carry NaN; 0 is the only safe reading.
        XCTAssertEqual(GVoice.gain(in: manifest(.nan)), 0)
    }

    // MARK: - Application

    /// The trim is applied to OUTPUT, so it must actually move the level.
    func testApplyGainMovesLevelByTheRequestedAmount() {
        let samples = (0 ..< 24_000).map { 0.1 * sin(2 * .pi * 220 * Float($0) / 24_000) }
        let up = AudioAssembler.applyGain(floats: samples, db: 6)
        func rms(_ s: [Float]) -> Float { (s.reduce(0) { $0 + $1 * $1 } / Float(s.count)).squareRoot() }
        XCTAssertEqual(20 * log10(rms(up) / rms(samples)), 6, accuracy: 0.2)
    }

    func testZeroGainIsExactlyIdentity() {
        let samples = (0 ..< 1_000).map { 0.4 * sin(Float($0) / 7) }
        XCTAssertEqual(AudioAssembler.applyGain(floats: samples, db: 0), samples)
    }

    /// A trim that pushes a loud take past full scale must bend, not tear.
    func testTrimNeverClipsPastFullScale() {
        let hot = (0 ..< 24_000).map { 0.9 * sin(2 * .pi * 220 * Float($0) / 24_000) }
        let out = AudioAssembler.applyGain(floats: hot, db: GVoice.maxGainDb)
        XCTAssertLessThanOrEqual(out.map { abs($0) }.max() ?? 0, 1.0)
    }

    // MARK: - Travel

    /// The trim belongs to the VOICE, so it has to survive the round trip a
    /// voice actually makes — otherwise the recipient re-dials it by hand, which
    /// is the thing carrying it in the manifest exists to avoid.
    func testGainSurvivesExportAndImport() throws {
        let source = try library()
        let saved = try source.save(name: "Traveller", refWav: wav(amplitude: 0.3), refText: "hello")
        try source.setGain(saved.slug, gainDb: -2.5)

        let pack = try GVoice.export(saved.slug, from: source)
        let destination = try library()
        let imported = try GVoice.import(pack, into: destination)

        XCTAssertEqual(try destination.get(imported.slug).0.gain, -2.5)
    }

    /// A voice with no trim must export WITHOUT the key, so "unset" stays
    /// distinguishable from "deliberately flat" on the far side.
    func testAnUntrimmedVoiceDoesNotWriteTheKey() throws {
        let lib = try library()
        let saved = try lib.save(name: "Plain", refWav: wav(amplitude: 0.3), refText: "hello")
        let pack = try GVoice.export(saved.slug, from: lib)
        let archive = try Archive(data: pack, accessMode: .read)
        var json = Data()
        _ = try archive.extract(archive["manifest.json"]!) { json.append($0) }
        XCTAssertNil(try JSONDecoder().decode(GVoice.Manifest.self, from: json).gain)
        // Absent from the BYTES, not merely decoding to nil — a written `null`
        // would still erase the unset/deliberately-flat distinction downstream.
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("gain"))
    }

    // MARK: - Variant resolution

    /// Trimming a base voice must move its variants too, or every trim would
    /// have to be repeated across a voice's variants and kept in sync by hand.
    func testAVariantInheritsItsBaseTrim() throws {
        let lib = try library()
        let base = try lib.save(name: "Cruz", refWav: wav(amplitude: 0.3), refText: "hi")
        try lib.saveAt(slug: "cruz-hype", name: "Cruz", refWav: wav(amplitude: 0.3),
                       refText: "hi", variantOf: base.slug)
        try lib.setGain(base.slug, gainDb: -2)
        XCTAssertEqual(lib.gainDb(for: "cruz-hype"), -2)
    }

    /// …but a variant that sets its OWN trim wins, which is what makes the
    /// expressive variants tunable — a shouted take sits hotter than a whisper.
    func testAVariantsOwnTrimBeatsTheBase() throws {
        let lib = try library()
        let base = try lib.save(name: "Ogre", refWav: wav(amplitude: 0.3), refText: "hi")
        try lib.saveAt(slug: "ogre-angry", name: "Ogre", refWav: wav(amplitude: 0.3),
                       refText: "hi", variantOf: base.slug)
        try lib.setGain(base.slug, gainDb: -2)
        try lib.setGain("ogre-angry", gainDb: 3)
        XCTAssertEqual(lib.gainDb(for: "ogre-angry"), 3)
        XCTAssertEqual(lib.gainDb(for: base.slug), -2)
    }

    func testAnUnknownOrUntrimmedVoiceResolvesToFlat() throws {
        let lib = try library()
        let saved = try lib.save(name: "Plainer", refWav: wav(amplitude: 0.3), refText: "hi")
        XCTAssertEqual(lib.gainDb(for: saved.slug), 0)
        XCTAssertEqual(lib.gainDb(for: "no-such-voice"), 0)
    }

    // MARK: - The standard still applies underneath

    /// Re-recording a voice through `update` used to drop it back to whatever
    /// level the microphone gave, silently undoing the standard for that voice
    /// while `save` and `saveAt` still honoured it. The trim sits on top of the
    /// standard, so the standard has to hold at EVERY write site.
    func testUpdatingAReferenceStillMeetsTheStandard() throws {
        let lib = try library()
        let saved = try lib.save(name: "Rerecorded", refWav: wav(amplitude: 0.3), refText: "hi")
        _ = try lib.update(saved.slug, refWav: wav(amplitude: 0.02))   // a quiet retake

        let stored = try Data(contentsOf: lib.directory
            .appendingPathComponent(saved.slug).appendingPathComponent("ref.wav"))
        guard let chunk = RefLoudness.dataChunk(in: stored) else { return XCTFail("no chunk") }
        var samples = [Float](repeating: 0, count: chunk.length / 2)
        stored.withUnsafeBytes { raw in
            let b = raw.baseAddress!.advanced(by: chunk.offset)
            for i in 0 ..< samples.count {
                let lo = UInt16(b.load(fromByteOffset: i * 2, as: UInt8.self))
                let hi = UInt16(b.load(fromByteOffset: i * 2 + 1, as: UInt8.self))
                samples[i] = Float(Int16(bitPattern: lo | (hi << 8))) / 32768
            }
        }
        XCTAssertEqual(Loudness.lufs(samples, sampleRate: chunk.sampleRate),
                       AudioAssembler.referenceLoudnessLUFS, accuracy: 0.5)
    }
}
