import Foundation
import GVoiceKit
import QwenANE
import XCTest

@testable import EngineKit

func unwrapSection(_ ref: URL, _ text: String, file: StaticString = #filePath, line: UInt = #line) async throws -> ReferenceSections.Audio8Section {
    let section = await ReferenceSections.audio8Section(forReference: ref, refText: text)
    return try XCTUnwrap(section, file: file, line: line)
}

/// Audio8's stored 20 s section (`engines/audio8/`) and its cached reference codes. Everything here is
/// synthetic audio and transcripts (public repo); the model-backed tests are skipped unless
/// AUDIO8_MODEL_DIR / AUDIO8_REF_WAV / AUDIO8_REF_TEXT are set.
final class ReferenceSectionsTests: XCTestCase {
    private let rate = 24_000
    private var dirs: [URL] = []

    override func tearDown() {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    /// A tone burst standing in for a sentence, then a short silence.
    private func sentences(count: Int, seconds: Double, gap: Double = 0.5, frequency: Float = 220) -> [Float] {
        var out: [Float] = []
        for _ in 0 ..< count {
            for i in 0 ..< Int(seconds * Double(rate)) {
                out.append(0.4 * sin(2 * Float.pi * frequency * Float(i) / Float(rate)))
            }
            out.append(contentsOf: [Float](repeating: 0, count: Int(gap * Double(rate))))
        }
        return out
    }

    private func transcript(sentences n: Int) -> String {
        (1 ... n).map { "Sentence number \($0) has a few plain words." }.joined(separator: " ")
    }

    private func makeVoice(_ samples: [Float]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("audio8-sections-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        let ref = dir.appendingPathComponent("ref.wav")
        try ReferenceSection.wavData(samples, sampleRate: rate).write(to: ref)
        return ref
    }

    func testAudio8SectionCutForLongMaster() async throws {
        let master = sentences(count: 13, seconds: 5.5)   // 78 s
        let text = transcript(sentences: 13)
        let ref = try makeVoice(master)
        let section = try await unwrapSection(ref, text)
        let stored = try LuxOnnx.loadMono24k(section.audioURL)
        XCTAssertLessThanOrEqual(Double(stored.count) / Double(rate), ReferenceSections.audio8MaxSeconds + 0.01)
        XCTAssertGreaterThan(Double(stored.count) / Double(rate), 10)
        XCTAssertNotEqual(section.text, text, "the section's transcript, not the master's")
        XCTAssertLessThan(section.text.count, text.count)
        XCTAssertTrue(section.text.hasSuffix("."), "ends at a sentence boundary: \(section.text)")
        XCTAssertTrue(text.contains(section.text), "a slice of the master's words")
        let meta = try XCTUnwrap(LuxReferenceWindow.storedRendition(forReference: ref, engine: "audio8"))
        XCTAssertEqual(meta.derivedFrom?.sourceSha256, ReferenceSection.sha256Hex(ofFile: ref))
        XCTAssertEqual(meta.audio, "engines/audio8/ref.wav")
    }

    func testAudio8ShortMasterUsedWhole() async throws {
        let master = sentences(count: 3, seconds: 2.5)   // 9 s
        let text = transcript(sentences: 3)
        let ref = try makeVoice(master)
        let section = try await unwrapSection(ref, text)
        XCTAssertEqual(section.text, text, "full transcript, no cut")
        let stored = try LuxOnnx.loadMono24k(section.audioURL)
        XCTAssertEqual(stored.count, master.count, accuracy: rate / 100, "the whole master")
    }

    func testAudio8SectionStaleWhenMasterChanges() async throws {
        let ref = try makeVoice(sentences(count: 13, seconds: 5.5))
        let first = try await unwrapSection(ref, transcript(sentences: 13))
        XCTAssertNotNil(LuxReferenceWindow.storedRendition(forReference: ref, engine: "audio8"))
        // A cached-codes file from the old section must not outlive it.
        try ReferenceSections.audio8StoreCodes([Int32](repeating: 1, count: 10 * 4), frames: 4, for: first)
        XCTAssertNotNil(ReferenceSections.audio8CachedCodes(for: first))

        try ReferenceSection.wavData(sentences(count: 9, seconds: 5.5, frequency: 330), sampleRate: rate).write(to: ref)
        XCTAssertNil(LuxReferenceWindow.storedRendition(forReference: ref, engine: "audio8"), "a new master makes the section stale")
        let second = try await unwrapSection(ref, transcript(sentences: 9))
        XCTAssertEqual(LuxReferenceWindow.storedRendition(forReference: ref, engine: "audio8")?.derivedFrom?.sourceSha256,
                       ReferenceSection.sha256Hex(ofFile: ref))
        XCTAssertNil(ReferenceSections.audio8CachedCodes(for: second), "codes of the replaced section are gone")
    }

    func testAudio8NoTranscriptHasNoSection() async throws {
        let ref = try makeVoice(sentences(count: 3, seconds: 2.5))
        let none = await ReferenceSections.audio8Section(forReference: ref, refText: "  ")
        XCTAssertNil(none)
        XCTAssertNil(LuxReferenceWindow.storedRendition(forReference: ref, engine: "audio8"))
    }

    func testPrepareWritesAudio8SectionWithoutAModel() async throws {
        let ref = try makeVoice(sentences(count: 13, seconds: 5.5))
        let written = await ReferenceSections.prepare(referenceURL: ref, refText: transcript(sentences: 13))
        XCTAssertTrue(written.contains("audio8"), "\(written)")
        let again = await ReferenceSections.prepare(referenceURL: ref, refText: transcript(sentences: 13))
        XCTAssertFalse(again.contains("audio8"), "a current section is kept")
    }

    func testCodesRoundTripAndStaleByAge() async throws {
        let ref = try makeVoice(sentences(count: 3, seconds: 2.5))
        let section = try await unwrapSection(ref, transcript(sentences: 3))
        XCTAssertNil(ReferenceSections.audio8CachedCodes(for: section))
        let values = (0 ..< 10 * 7).map { Int32($0) }
        try ReferenceSections.audio8StoreCodes(values, frames: 7, for: section)
        let cached = try XCTUnwrap(ReferenceSections.audio8CachedCodes(for: section))
        XCTAssertEqual(cached.values, values)
        XCTAssertEqual(cached.frames, 7)
        // numpy-readable header: magic, version 1.0, 64-byte aligned.
        let bytes = try Data(contentsOf: section.codesURL)
        XCTAssertEqual(Array(bytes.prefix(8)), [0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59, 1, 0])
        let headerLen = Int(bytes[8]) | Int(bytes[9]) << 8
        XCTAssertEqual((10 + headerLen) % 64, 0)
        XCTAssertEqual(bytes.count, 10 + headerLen + values.count * 4)
        // A section newer than its codes (replaced by another tool) invalidates them.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: section.codesURL.path)
        XCTAssertNil(ReferenceSections.audio8CachedCodes(for: section))
    }
}

/// Model-backed (skipped unless AUDIO8_MODEL_DIR is set).
final class Audio8SectionModelTests: XCTestCase {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    private func loadModel() async throws -> MLXSpeechModel {
        guard let dir = Self.env["AUDIO8_MODEL_DIR"], !dir.isEmpty else {
            throw XCTSkip("set AUDIO8_MODEL_DIR to run Audio8 model-backed tests")
        }
        let wav = Self.env["AUDIO8_REF_WAV"] ?? "", text = Self.env["AUDIO8_REF_TEXT"] ?? ""
        try XCTSkipUnless(!wav.isEmpty && !text.isEmpty && FileManager.default.fileExists(atPath: wav),
                          "set AUDIO8_REF_WAV and AUDIO8_REF_TEXT")
        let provider = MLXModelProvider(modelPathResolver: { $0 == .audio8 ? dir : nil })
        let loaded = try await provider.loadModel(backend: .audio8)
        return try XCTUnwrap(loaded as? MLXSpeechModel)
    }

    /// The reference copied into a throwaway voice folder, so the stored section lands there.
    private func voiceCopy() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("audio8-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ref = dir.appendingPathComponent("ref.wav")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: Self.env["AUDIO8_REF_WAV"] ?? ""), to: ref)
        return ref
    }

    func testAudio8CodesCachedOnce() async throws {
        let model = try await loadModel()
        let ref = try voiceCopy()
        defer { try? FileManager.default.removeItem(at: ref.deletingLastPathComponent()) }
        let request = ProviderRequest(text: "Hello there, friend.", refAudioPath: ref.path,
                                      refText: Self.env["AUDIO8_REF_TEXT"], temperature: 0.7, topP: 0.8, seed: 3)
        _ = try await model.synthesize(request)
        let codes = ref.deletingLastPathComponent().appendingPathComponent("engines/audio8/ref_codes.npy")
        let first = try FileManager.default.attributesOfItem(atPath: codes.path)[.modificationDate] as? Date
        XCTAssertEqual(model.audio8EncodeCalls.value, 1)
        _ = try await model.synthesize(request)
        let second = try FileManager.default.attributesOfItem(atPath: codes.path)[.modificationDate] as? Date
        XCTAssertEqual(first, second, "codes file untouched by the second render")
        XCTAssertEqual(model.audio8EncodeCalls.value, 1, "second render does not re-encode")
    }

    func testAudio8Accepts24kReference() async throws {
        let model = try await loadModel()
        let ref = try voiceCopy()
        defer { try? FileManager.default.removeItem(at: ref.deletingLastPathComponent()) }
        XCTAssertEqual(try LuxOnnx.loadMono24k(ref).isEmpty, false)
        let request = ProviderRequest(text: "Hello there, friend.", refAudioPath: ref.path,
                                      refText: Self.env["AUDIO8_REF_TEXT"], temperature: 0.7, topP: 0.8, seed: 3)
        let samples = try await model.synthesize(request)
        XCTAssertGreaterThan(samples.count, model.sampleRate / 2)
        let section = try await unwrapSection(ref, Self.env["AUDIO8_REF_TEXT"] ?? "")
        let cached = try XCTUnwrap(ReferenceSections.audio8CachedCodes(for: section))
        let seconds = Double(try LuxOnnx.loadMono24k(section.audioURL).count) / 24_000
        XCTAssertEqual(Double(cached.frames), seconds * 21.5, accuracy: 2, "frames \(cached.frames) for \(seconds) s")
    }

    /// A long master (env-provided, local only) is cut once to <= 20 s and renders from the section.
    func testAudio8LongMasterRendersFromTheStoredSection() async throws {
        guard let wav = Self.env["AUDIO8_LONG_MASTER_WAV"], let text = Self.env["AUDIO8_LONG_MASTER_TEXT"],
              FileManager.default.fileExists(atPath: wav) else { throw XCTSkip("set AUDIO8_LONG_MASTER_WAV/_TEXT") }
        let model = try await loadModel()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("audio8-long-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ref = dir.appendingPathComponent("ref.wav")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: wav), to: ref)
        let samples = try await model.synthesize(ProviderRequest(
            text: "Hello there, friend.", refAudioPath: ref.path, refText: text, temperature: 0.7, topP: 0.8, seed: 3))
        XCTAssertGreaterThan(samples.count, model.sampleRate / 2)
        let section = try await unwrapSection(ref, text)
        XCTAssertLessThanOrEqual(Double(try LuxOnnx.loadMono24k(section.audioURL).count) / 24_000, 20.01)
        XCTAssertLessThan(section.text.count, text.count)
    }
}
