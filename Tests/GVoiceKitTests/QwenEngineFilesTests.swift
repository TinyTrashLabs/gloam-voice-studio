import XCTest
import ZIPFoundation
@testable import GVoiceKit

final class QwenEngineFilesTests: XCTestCase {
    static func npy(_ bytes: [UInt8], descr: String, shape: String) -> Data {
        var header = "{'descr': '\(descr)', 'fortran_order': False, 'shape': \(shape), }"
        let total = 10 + header.utf8.count + 1
        header += String(repeating: " ", count: (64 - total % 64) % 64) + "\n"
        var d = Data([0x93]) + Data("NUMPY".utf8) + Data([1, 0])
        let n = UInt16(header.utf8.count)
        d.append(contentsOf: [UInt8(n & 0xFF), UInt8(n >> 8)])
        d.append(Data(header.utf8))
        d.append(contentsOf: bytes)
        return d
    }

    static func codes(frames: Int = 25, value: (Int) -> Int32 = { Int32($0 % 2048) }) -> Data {
        var b = [UInt8]()
        for i in 0..<(16 * frames) { withUnsafeBytes(of: value(i).littleEndian) { b.append(contentsOf: $0) } }
        return npy(b, descr: "<i4", shape: "(1, 16, \(frames))")
    }

    static func spk(_ f: (Int) -> Float = { Float($0) / 1024 }) -> Data {
        var b = [UInt8]()
        for i in 0..<1024 { withUnsafeBytes(of: f(i).bitPattern.littleEndian) { b.append(contentsOf: $0) } }
        return npy(b, descr: "<f4", shape: "(1024,)")
    }

    static let audio = Data("pretend wav".utf8)

    static func sample(audio: Data = audio, window: (Double, Double)? = nil) -> QwenEngineFiles {
        QwenEngineFiles(
            text: "hello there",
            derivedFrom: .init(audio: window == nil ? "source/ref.wav" : "engines/lux-tts/ref.wav",
                               sha256: QwenEngineFiles.sha256Hex(audio),
                               startSeconds: window?.0, endSeconds: window?.1,
                               by: "QwenVoicePrep", prepVersion: 1, mel: "upstream"),
            refCodes: codes(), spkEmbedding: spk())
    }

    /// A minimal pack: manifest + source + an unrelated engine, plus an unknown manifest key.
    static func pack(extra: [(String, Data)] = [], engines: String = #"{"supertonic":{"base":["engines/supertonic/style.json"]}}"#) throws -> Data {
        let manifest = #"{"gvoice":2,"name":"T","variants":["base"],"mystery":{"keep":1},"source":{"base":{"audio":"source/ref.wav","text":"hello there"}},"engines":\#(engines)}"#
        return try GVoice.makeArchive(entries: [("manifest.json", Data(manifest.utf8)),
                                                ("source/ref.wav", audio),
                                                ("engines/supertonic/style.json", Data("{}".utf8))] + extra)
    }

    // MARK: validation

    func testValidSampleValidates() throws {
        try Self.sample().validate()
        try Self.sample(window: (0, 12.5)).validate()
    }

    func testRejectsMalformed() {
        func bad(_ mutate: (inout QwenEngineFiles) -> Void, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
            var s = Self.sample(); mutate(&s)
            XCTAssertThrowsError(try s.validate(), why, file: file, line: line)
        }
        bad({ $0.text = "  " }, "empty text")
        bad({ $0.derivedFrom.sha256 = "ABC" }, "sha")
        bad({ $0.derivedFrom.sha256 = String(repeating: "A", count: 64) }, "uppercase sha")
        bad({ $0.derivedFrom.audio = "../x.wav" }, "traversal")
        bad({ $0.derivedFrom.audio = "/etc/passwd" }, "absolute")
        bad({ $0.derivedFrom.audio = "avatar.png" }, "outside source/engines")
        bad({ $0.derivedFrom.prepVersion = 0 }, "prepVersion")
        bad({ $0.derivedFrom.startSeconds = 1 }, "half window")
        bad({ $0.derivedFrom.startSeconds = 5; $0.derivedFrom.endSeconds = 2 }, "inverted window")
        bad({ $0.refCodes = Self.codes(value: { _ in 2048 }) }, "code out of range")
        bad({ $0.refCodes = Self.codes(value: { _ in -1 }) }, "negative code")
        bad({ $0.refCodes = Self.codes(frames: 300) }, "too many frames")
        bad({ $0.refCodes = Self.codes().dropLast(4) }, "truncated codes")
        bad({ $0.refCodes = Self.npy([0, 0, 0, 0], descr: "<i8", shape: "(1, 16, 25)") }, "dtype")
        bad({ $0.spkEmbedding = Self.spk { _ in .nan } }, "nan")
        bad({ $0.spkEmbedding = Self.npy([UInt8](repeating: 0, count: 2048 * 4), descr: "<f4", shape: "(2048,)") }, "1.7B-sized embedding")
        bad({ $0.spkEmbedding = Data("nope".utf8) }, "not npy")
        bad({ $0.refCodes = Data(repeating: 0, count: QwenEngineFiles.maxNPYBytes + 1) }, "oversized")
    }

    func testIsCurrent() {
        let s = Self.sample()
        XCTAssertTrue(s.isCurrent(forAudio: Self.audio, transcript: " hello there\n", prepVersion: 1, mel: "upstream"))
        XCTAssertFalse(s.isCurrent(forAudio: Data("other".utf8), transcript: "hello there", prepVersion: 1, mel: "upstream"))
        XCTAssertFalse(s.isCurrent(forAudio: Self.audio, transcript: "hello there", prepVersion: 2, mel: "upstream"))
        XCTAssertFalse(s.isCurrent(forAudio: Self.audio, transcript: "hello there", prepVersion: 1, mel: "other"))
        XCTAssertFalse(s.isCurrent(forAudio: Self.audio, transcript: "different words", prepVersion: 1, mel: "upstream"))
    }

    // MARK: members and decode

    func testMembersLayoutAndDecodeRoundTrip() throws {
        let s = Self.sample(window: (1.5, 14))
        let m = try s.members()
        XCTAssertEqual(Set(m.keys), ["engines/qwen3-0.6b/ref_codes.npy", "engines/qwen3-0.6b/spk_embed.npy", "engines/qwen3-0.6b/voice.json"])
        let json = try JSONSerialization.jsonObject(with: m["engines/qwen3-0.6b/voice.json"]!) as! [String: Any]
        XCTAssertEqual(json["refCodes"] as? String, "engines/qwen3-0.6b/ref_codes.npy")
        XCTAssertEqual(json["spkEmbedding"] as? String, "engines/qwen3-0.6b/spk_embed.npy")
        let d = json["derivedFrom"] as! [String: Any]
        XCTAssertEqual(d["by"] as? String, "QwenVoicePrep")
        XCTAssertEqual(d["startSeconds"] as? Double, 1.5)
        XCTAssertEqual(try QwenEngineFiles.decode(files: s.files()), s)
        XCTAssertEqual(try s.members(variant: "hype").keys.sorted().first, "engines/qwen3-0.6b/ref_codes-hype.npy")
        XCTAssertThrowsError(try s.members(variant: "../x"))
    }

    func testDecodeRejectsPathsOutsideTheFolder() throws {
        var files = try Self.sample().files()
        for evil in ["source/ref.wav", "engines/qwen3-0.6b/../x", "/abs/ref_codes.npy", "engines/other/ref_codes.npy", "engines/qwen3-0.6b/a/b.npy"] {
            var j = try JSONSerialization.jsonObject(with: files["voice.json"]!) as! [String: Any]
            j["refCodes"] = evil
            var f = files; f["voice.json"] = try JSONSerialization.data(withJSONObject: j)
            XCTAssertThrowsError(try QwenEngineFiles.decode(files: f), evil)
        }
        files["voice.json"] = Data(repeating: 0x20, count: QwenEngineFiles.maxVoiceJSONBytes + 1)
        XCTAssertThrowsError(try QwenEngineFiles.decode(files: files))
        files["voice.json"] = nil
        XCTAssertThrowsError(try QwenEngineFiles.decode(files: files))
    }

    // MARK: packs

    func testWriteReadPackKeepsEverythingElse() throws {
        let s = Self.sample()
        let original = try Self.pack()
        let out = try QwenEngineFiles.write(s, intoPack: original)
        XCTAssertEqual(QwenEngineFiles.read(fromPack: out), s)
        XCTAssertNil(QwenEngineFiles.read(fromPack: original))

        let archive = try Archive(data: out, accessMode: .read)
        XCTAssertNotNil(archive["source/ref.wav"])
        XCTAssertNotNil(archive["engines/supertonic/style.json"])
        var mdata = Data(); _ = try archive.extract(archive["manifest.json"]!) { mdata.append($0) }
        let m = try JSONSerialization.jsonObject(with: mdata) as! [String: Any]
        XCTAssertNotNil(m["mystery"], "unknown manifest keys survive")
        let eng = m["engines"] as! [String: Any]
        XCTAssertNotNil(eng["supertonic"])
        XCTAssertEqual((eng["qwen3-0.6b"] as! [String: [String]])["base"]!.count, 3)

        // Refreshing replaces; it does not accumulate.
        var s2 = s; s2.text = "hello there"; s2.refCodes = Self.codes(frames: 30)
        let again = try QwenEngineFiles.write(s2, intoPack: out)
        XCTAssertEqual(QwenEngineFiles.read(fromPack: again)?.refCodes, s2.refCodes)
        XCTAssertEqual(Set(try Archive(data: again, accessMode: .read).map(\.path)).filter { $0.hasPrefix("engines/qwen3") }.count, 3)
        // byte-stable
        XCTAssertEqual(try QwenEngineFiles.write(s2, intoPack: out), again)
    }

    func testReadIgnoresUnusablePack() throws {
        // listed but missing member
        let manifestOnly = try Self.pack(engines: #"{"qwen3-0.6b":{"base":["engines/qwen3-0.6b/voice.json"]}}"#)
        XCTAssertNil(QwenEngineFiles.read(fromPack: manifestOnly))
        // corrupt npy
        var bad = Self.sample(); bad.refCodes = Data("junk".utf8)
        let files = try Self.sample().members()
        var corrupt = files
        corrupt["engines/qwen3-0.6b/ref_codes.npy"] = bad.refCodes
        let listed = files.keys.sorted().map { "\"\($0)\"" }.joined(separator: ",")
        let pack = try Self.pack(extra: corrupt.sorted { $0.key < $1.key }.map { ($0.key, $0.value) },
                                 engines: #"{"qwen3-0.6b":{"base":[\#(listed)]}}"#)
        XCTAssertNil(QwenEngineFiles.read(fromPack: pack))
        XCTAssertNil(QwenEngineFiles.read(fromPack: Data("not a zip".utf8)))
    }

    func testReplacingEngineRefusesMembersOutsideItsFolder() throws {
        XCTAssertThrowsError(try GVoice.replacingEngine("qwen3-0.6b", variant: "base",
                                                         members: ["source/ref.wav": Data([1])], inPack: try Self.pack()))
        XCTAssertThrowsError(try GVoice.replacingEngine("qwen3-0.6b", variant: "base",
                                                         members: ["engines/qwen3-0.6b/../x": Data([1])], inPack: try Self.pack()))
    }
}

extension QwenEngineFilesTests {
    func testDecodedArraysMatchTheBytes() throws {
        let s = Self.sample()
        let codes = try s.decodedRefCodes()
        XCTAssertEqual(codes.count, 16)
        XCTAssertEqual(codes[0].count, 25)
        XCTAssertEqual(codes[1][0], 25)            // flat index 25 -> value 25 % 2048
        XCTAssertEqual(try s.decodedSpeakerEmbedding()[512], 0.5)
    }
}
