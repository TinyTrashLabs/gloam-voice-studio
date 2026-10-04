import XCTest
import GVoiceKit
@testable import QwenANE

/// `prepareEngineFolder`: a master past the encoder gets its section chosen ONCE and stored in
/// `engines/qwen3-0.6b/`; every later call reads the stored folder and cuts nothing.
final class QwenVoicePrepFolderTests: XCTestCase {
    private let limit = 480_000   // 20 s
    private var voiceDir: URL!
    private var cache: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qwen-folder-\(UUID().uuidString)")
        voiceDir = root.appendingPathComponent("voice"); cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: voiceDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    private func master(seconds: Double) -> Data {
        ReferenceSection.wavData(Self.speech(seconds: seconds), sampleRate: 24_000)
    }
    private static func speech(seconds: Double) -> [Float] {
        (0 ..< Int(seconds * 24_000)).map { i in
            let t = Double(i) / 24_000
            return t.truncatingRemainder(dividingBy: 0.9) < 0.6 ? 0.3 * Float(sin(2 * .pi * 180 * t)) : 0
        }
    }

    /// Stands in for the Core ML encoders; counts its runs.
    private final class Encoder { var runs = 0 }
    private func fake(_ e: Encoder) -> (Data, String) throws -> QwenVoiceFiles {
        { wav, text in
            e.runs += 1
            let all = try QwenVoicePrep.samples(of: wav)
            let T = QwenVoicePrep.codeFrames(samples: ReferenceTail.end(of: all, sampleRate: 24_000))
            return QwenVoiceFiles(refText: text, refCodes: (0..<16).map { g in (0..<T).map { ($0 * 7 + g) % 2048 } },
                                  spkEmbedding: [Float](repeating: 0.25, count: 1024))
        }
    }
    private func run(_ master: Data, _ e: Encoder, words: String = "alpha beta gamma. delta epsilon zeta. eta theta iota.",
                     heard: String? = nil) async throws -> QwenVoicePrep.Prepared {
        try await QwenVoicePrep.prepareEngineFolder(
            voiceDir: voiceDir, masterWAV: master, transcript: words, cacheDirectory: cache,
            transcribe: { _ in heard }, limitSamples: limit, encode: fake(e))
    }
    private var sectionURL: URL { voiceDir.appendingPathComponent(QwenVoicePrep.sectionMember) }

    func testALongMasterGetsItsSectionStoredInThePack() async throws {
        let m = master(seconds: 50), e = Encoder()
        let r = try await run(m, e)
        XCTAssertEqual(e.runs, 1)
        let stored = try XCTUnwrap(QwenVoicePrep.storedFolder(in: voiceDir))
        let d = stored.derivedFrom
        XCTAssertEqual(d.audio, QwenVoicePrep.sectionMember)
        XCTAssertEqual(d.sourceSha256, ReferenceSection.sha256Hex(m))
        let wav = try Data(contentsOf: sectionURL)
        XCTAssertEqual(d.sha256, ReferenceSection.sha256Hex(wav), "the codes are computed FROM the stored section")
        let seconds = Double(try QwenVoicePrep.samples(of: wav).count) / 24_000
        XCTAssertLessThanOrEqual(seconds, 20); XCTAssertGreaterThan(seconds, 12)
        XCTAssertEqual(try XCTUnwrap(d.endSeconds) - XCTUnwrap(d.startSeconds), seconds, accuracy: 0.01)
        XCTAssertFalse(stored.text.isEmpty)
        XCTAssertEqual(r.files.refText, stored.text)
    }

    func testALaterRenderReadsTheStoredFolderAndCutsNothing() async throws {
        let m = master(seconds: 50)
        let heard = (0 ..< 40).map { "heard\($0)" }.joined(separator: " ")   // a plausible rate for the cut
        let first = try await run(m, Encoder(), heard: heard)
        let wav = try Data(contentsOf: sectionURL)
        let voiceJSON = try Data(contentsOf: voiceDir.appendingPathComponent("engines/qwen3-0.6b/voice.json"))
        // Fresh in-process state: no cache directory, an encoder and a recognizer that would give different answers.
        try? FileManager.default.removeItem(at: cache)
        let e = Encoder()
        let again = try await run(m, e, words: "completely different words now", heard: "different heard words")
        XCTAssertEqual(e.runs, 0, "the encoders did not run")
        XCTAssertEqual(again.origin, .pack)
        XCTAssertEqual(again.files.refCodes, first.files.refCodes)
        XCTAssertEqual(again.files.refText, heard, "the stored transcript, not a new one")
        XCTAssertEqual(try Data(contentsOf: sectionURL), wav, "the section is byte-identical")
        XCTAssertEqual(try Data(contentsOf: voiceDir.appendingPathComponent("engines/qwen3-0.6b/voice.json")), voiceJSON)
    }

    func testAReplacedMasterReplacesTheSection() async throws {
        _ = try await run(master(seconds: 50), Encoder())
        let before = try Data(contentsOf: sectionURL)
        let other = ReferenceSection.wavData(Self.speech(seconds: 44).map { $0 * 0.5 }, sampleRate: 24_000)
        _ = try await run(other, Encoder())
        XCTAssertNotEqual(try Data(contentsOf: sectionURL), before)
        XCTAssertEqual(QwenVoicePrep.storedFolder(in: voiceDir)?.derivedFrom.sourceSha256, ReferenceSection.sha256Hex(other))
    }

    func testAMasterThatFitsStoresNoSection() async throws {
        let m = master(seconds: 12)
        _ = try await run(m, Encoder())
        XCTAssertFalse(FileManager.default.fileExists(atPath: sectionURL.path))
        XCTAssertEqual(QwenVoicePrep.storedFolder(in: voiceDir)?.derivedFrom.audio, "source/ref.wav")
    }
}
