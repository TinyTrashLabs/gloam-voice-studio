import XCTest
@testable import EngineKit

/// `LuxSpeechModel.load(from:phonemizer:leadInTrimming:)` — the entry point
/// an App Store client uses. The default `load(from:)` resolves misaki's
/// dictionaries from HuggingFace on first use and requests Speech
/// authorisation for the lead-in trimmer; a client that ships its own G2P
/// and owns its permissions needs neither, so both must be injectable.
///
/// The live test needs the converted LuxTTS weights plus a reference clip
/// on disk, so it is gated behind ENGINEKIT_LIVE_TESTS=1 like the other
/// real-model smoke tests.
final class LuxSpeechModelLoadTests: XCTestCase {
    /// Records every call and answers with one fixed, in-vocab phoneme run
    /// so the tokenizer never sees an OOV token whatever the text was.
    private final class RecordingPhonemizer: PhonemizerProviding, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var inputs: [String] = []
        func phonemize(_ normalizedEnglishText: String) throws -> [String] {
            lock.lock(); defer { lock.unlock() }
            inputs.append(normalizedEnglishText)
            return ["h", "ə", "l", "ˈ", "o", "ʊ", " ", "w", "ˈ", "ɜ", "ː", "l", "d", "."]
        }
    }

    private static var weightsDir: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["LUXTTS_WEIGHTS_DIR"]
            ?? NSString(string: "~/Library/Group Containers/UT233385J9.fm.gloam/Models/lux-tts")
                .expandingTildeInPath)
    }

    private static var referenceClip: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["LUXTTS_REFERENCE_WAV"]
            ?? NSString(string: "~/Library/Group Containers/UT233385J9.fm.gloam/Voices/billie-frost/ref.wav")
                .expandingTildeInPath)
    }

    private static var liveTestsEnabled: Bool {
        ProcessInfo.processInfo.environment["ENGINEKIT_LIVE_TESTS"] == "1"
    }

    // MARK: - No weights needed

    /// A missing weights directory fails on the weights check — before the
    /// phonemizer is consulted, and without touching misaki or the network.
    func testMissingWeightsFailBeforeThePhonemizerIsUsed() async {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("lux-load-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let phonemizer = RecordingPhonemizer()
        do {
            _ = try await LuxSpeechModel.load(
                from: empty, phonemizer: phonemizer, leadInTrimming: false)
            XCTFail("expected weightsNotFound")
        } catch LuxModelLoadError.weightsNotFound(let path) {
            XCTAssertTrue(path.hasPrefix(empty.path), path)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(phonemizer.inputs.isEmpty, "phonemizer must not run before weights load")
    }

    // MARK: - Live

    /// The injected phonemizer is what tokenizes both the reference
    /// transcript and the text; synthesis completes with the lead-in trimmer
    /// off (no Speech authorisation involved).
    func testInjectedPhonemizerDrivesSynthesis() async throws {
        try XCTSkipUnless(Self.liveTestsEnabled, "set ENGINEKIT_LIVE_TESTS=1")
        try XCTSkipUnless(
            FileManager.default.fileExists(
                atPath: Self.weightsDir.appendingPathComponent("lux_model.safetensors").path),
            "no LuxTTS weights at \(Self.weightsDir.path)")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: Self.referenceClip.path),
            "no reference clip at \(Self.referenceClip.path)")

        let phonemizer = RecordingPhonemizer()
        let model = try await LuxSpeechModel.load(
            from: Self.weightsDir, phonemizer: phonemizer, leadInTrimming: false)
        XCTAssertTrue(phonemizer.inputs.isEmpty, "load must not phonemize anything")

        let samples = try await model.synthesize(ProviderRequest(
            text: "Hello world.",
            refAudioPath: Self.referenceClip.path,
            refText: "Hello world.",
            numSteps: 2))
        XCTAssertGreaterThan(samples.count, model.sampleRate / 2, "under half a second of audio")
        XCTAssertGreaterThanOrEqual(phonemizer.inputs.count, 2, "reference transcript + text")
        XCTAssertTrue(phonemizer.inputs.allSatisfy { $0.lowercased().contains("hello") },
                      "\(phonemizer.inputs)")
    }
}
