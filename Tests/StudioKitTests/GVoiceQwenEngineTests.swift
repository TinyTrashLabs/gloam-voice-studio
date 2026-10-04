import XCTest
@testable import GVoiceKit
@testable import StudioKit

/// `engines/qwen3-0.6b/` (docs/gvoice-format.md) through the real library: import keeps it, export
/// re-emits it, and it never travels without `source/`.
final class GVoiceQwenEngineTests: XCTestCase {
    var dir: URL!
    var lib: VoiceLibrary!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("gvoice-qwen-\(UUID().uuidString)")
        lib = VoiceLibrary(directory: dir)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func npy(_ bytes: [UInt8], descr: String, shape: String) -> Data {
        var header = "{'descr': '\(descr)', 'fortran_order': False, 'shape': \(shape), }"
        let total = 10 + header.utf8.count + 1
        header += String(repeating: " ", count: (64 - total % 64) % 64) + "\n"
        var d = Data([0x93]) + Data("NUMPY".utf8) + Data([1, 0])
        let n = UInt16(header.utf8.count)
        d.append(contentsOf: [UInt8(n & 0xFF), UInt8(n >> 8)])
        d.append(Data(header.utf8)); d.append(contentsOf: bytes)
        return d
    }

    private func payload(for audio: Data) -> QwenEngineFiles {
        var c = [UInt8](), s = [UInt8]()
        for i in 0..<(16 * 10) { withUnsafeBytes(of: Int32(i * 11 % 2048).littleEndian) { c.append(contentsOf: $0) } }
        for i in 0..<1024 { withUnsafeBytes(of: (Float(i) / 7).bitPattern.littleEndian) { s.append(contentsOf: $0) } }
        return QwenEngineFiles(
            text: "hello there",
            derivedFrom: .init(audio: "source/ref.wav", sha256: QwenEngineFiles.sha256Hex(audio),
                               by: "QwenVoicePrep", prepVersion: 1, mel: "upstream"),
            refCodes: npy(c, descr: "<i4", shape: "(1, 16, 10)"), spkEmbedding: npy(s, descr: "<f4", shape: "(1024,)"))
    }

    func testRoundTripThroughLibraryKeepsAndReEmitsTheFolder() throws {
        let audio = Data([1, 2, 3, 4, 5])
        let p = payload(for: audio)
        _ = try lib.save(name: "Cruz", refWav: audio, refText: "hello there",
                         engines: ["qwen3-0.6b": try p.files()])
        // Imported voices keep the folder too.
        let pack = try GVoice.export("cruz", from: lib)
        XCTAssertEqual(QwenEngineFiles.read(fromPack: pack), p)

        try lib.delete("cruz")
        _ = try GVoice.import(pack, into: lib)
        let entry = try lib.entry("cruz")
        XCTAssertEqual(Set(entry.engines["qwen3-0.6b"]?.keys ?? [:].keys), ["ref_codes.npy", "spk_embed.npy", "voice.json"])
        let again = try GVoice.export("cruz", from: lib)
        XCTAssertEqual(QwenEngineFiles.read(fromPack: again), p)
        // The stored source is the very file the digest names (no re-levelling for this audio).
        XCTAssertEqual(QwenEngineFiles.sha256Hex(try Data(contentsOf: try XCTUnwrap(entry.refURL))), p.derivedFrom.sha256)
    }

    func testFolderNeverTravelsWithoutSource() throws {
        let audio = Data([9, 8, 7])
        _ = try lib.save(name: "Cruz", refWav: audio, refText: "hello there",
                         engines: ["qwen3-0.6b": try payload(for: audio).files(),
                                   "supertonic": ["style.json": Data("{}".utf8)]])
        let pack = try GVoice.export("cruz", from: lib, includeSource: false)
        XCTAssertNotNil(GVoice.member("engines/supertonic/style.json", ofPack: pack), "other renditions still travel")
        XCTAssertNil(QwenEngineFiles.read(fromPack: pack))
        let manifest = try GVoice.manifest(ofPack: pack)
        XCTAssertNil(manifest.engines?["qwen3-0.6b"])
        XCTAssertNil(GVoice.member("engines/qwen3-0.6b/ref_codes.npy", ofPack: pack))
    }

    func testFolderIsNotARenditionForCapabilities() {
        let caps = VoiceCapabilities(hasSource: false, hasRefText: false, engines: ["qwen3-0.6b"])
        XCTAssertFalse(caps.supports(.qwen06B), "codes without source cannot drive any backend")
        XCTAssertTrue(VoiceCapabilities(hasSource: true, hasRefText: true, engines: ["qwen3-0.6b"]).supports(.qwen06B))
    }

    /// The bundled packs: whichever carry the folder must verify against the audio the library keeps after import.
    func testBundledPacksCarryVerifiableFolders() throws {
        let packs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("packs")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: packs.path)) ?? []).filter { $0.hasSuffix(".gvoice") }
        guard !files.isEmpty else { throw XCTSkip("no packs/ directory") }
        for f in files {
            let data = try Data(contentsOf: packs.appendingPathComponent(f))
            guard let q = QwenEngineFiles.read(fromPack: data) else { XCTFail("\(f) has no usable engines/qwen3-0.6b"); continue }
            let m = try GVoice.manifest(ofPack: data)
            XCTAssertEqual(q.derivedFrom.sha256, QwenEngineFiles.sha256Hex(try XCTUnwrap(GVoice.member(q.derivedFrom.audio, ofPack: data))), f)
            // The transcript of the audio it was prepared from: source/ normally, or the
            // lux-tts window's own (its voice.json) for a reference over the encoder's 20 s.
            let expected: String? = q.derivedFrom.audio.hasPrefix("engines/lux-tts/")
                ? try GVoice.member("engines/lux-tts/voice.json", ofPack: data)
                    .flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["text"] as? String
                : m.source?["base"]?.text
            XCTAssertNotNil(expected, f)
            XCTAssertEqual(q.text.trimmingCharacters(in: .whitespacesAndNewlines),
                           expected?.trimmingCharacters(in: .whitespacesAndNewlines), f)
            let meta = try GVoice.import(data, into: lib)
            let entry = try lib.entry(meta.slug)
            let keptURL = q.derivedFrom.audio.hasPrefix("engines/lux-tts/")
                ? entry.engines["lux-tts"]?[(q.derivedFrom.audio as NSString).lastPathComponent]
                : entry.refURL
            let kept = try Data(contentsOf: try XCTUnwrap(keptURL))
            print("QWENPACK \(f): library ref sha matches pack digest = \(QwenEngineFiles.sha256Hex(kept) == q.derivedFrom.sha256)")
        }
    }
}
