import AVFoundation
import XCTest
@testable import EngineKit

final class QwenANEBackendTests: XCTestCase {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("qane-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    /// Lays down an (empty) model set: the resolver only checks the entries exist.
    private func fakeModelSet(at dir: URL) throws {
        for entry in QwenANEModelLocation.requiredFiles {
            let url = dir.appendingPathComponent(entry)
            if entry.contains(".") { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if entry.hasSuffix(".mlmodelc") { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
                else { try Data().write(to: url) } }
            else { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        }
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "qane-test-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    // MARK: backend facts

    func testBackendDeclaration() {
        let b = BackendID.qwen06BANE
        XCTAssertEqual(b.rawValue, "qwen3-0.6b-ane")
        XCTAssertFalse(b.isQwen, "isQwen means MLX Qwen with repo + quant folders")
        XCTAssertEqual(b.controls.voiceClone, .required)
        XCTAssertEqual(b.controls.instruct, .none)
        XCTAssertTrue(b.needsRefText)
        XCTAssertTrue(b.spec.needsRefAudio)
        XCTAssertEqual(b.spec.defaultSampleRate, 24000)
        XCTAssertEqual(b.surfaces, [.apiServer], "hand-installed model set: API only, not in pickers or the downloader")
        XCTAssertTrue(b.installsManually)
        XCTAssertFalse(BackendID.qwen06BMobile.installsManually)
        XCTAssertEqual(b.availableQuants, [])
    }

    func testPlannerRequiresAReference() {
        XCTAssertThrowsError(try RequestPlanner.plan(backend: .qwen06BANE, request: SynthesisRequest(text: "hi"))) {
            XCTAssertEqual($0 as? EngineError, .refAudioRequired(.qwen06BANE))
        }
    }

    // MARK: model location

    func testResolutionOrderIsEnvThenDefaultsThenApplicationSupport() throws {
        let env = try tempDir(), pref = try tempDir(), support = try tempDir()
        try fakeModelSet(at: env); try fakeModelSet(at: pref)
        try fakeModelSet(at: QwenANEModelLocation.defaultDirectory(appSupport: support))
        let defaults = isolatedDefaults()
        defaults.set(pref.path, forKey: QwenANEModelLocation.defaultsKey)

        XCTAssertEqual(try QwenANEModelLocation.resolve(environment: [QwenANEModelLocation.environmentKey: env.path],
                                                        defaults: defaults, appSupport: support).path, env.path)
        XCTAssertEqual(try QwenANEModelLocation.resolve(environment: [:], defaults: defaults, appSupport: support).path, pref.path)
        defaults.removeObject(forKey: QwenANEModelLocation.defaultsKey)
        XCTAssertEqual(try QwenANEModelLocation.resolve(environment: [:], defaults: defaults, appSupport: support).path,
                       QwenANEModelLocation.defaultDirectory(appSupport: support).path)
    }

    func testDefaultLocationIsApplicationSupportGloamVoiceStudioModels() {
        let support = URL(fileURLWithPath: "/tmp/AppSupport")
        XCTAssertEqual(QwenANEModelLocation.defaultDirectory(appSupport: support).path,
                       "/tmp/AppSupport/GloamVoiceStudio/Models/qwen3-0.6b-ane")
    }

    func testMissingModelSetNamesTheExpectedPath() throws {
        let support = try tempDir(), bad = try tempDir()
        XCTAssertThrowsError(try QwenANEModelLocation.resolve(
            environment: [QwenANEModelLocation.environmentKey: bad.path],
            defaults: isolatedDefaults(), appSupport: support)) { error in
            guard case EngineError.modelNotInstalled(let backend, let detail) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(backend, .qwen06BANE)
            XCTAssertTrue(detail.contains(QwenANEModelLocation.defaultDirectory(appSupport: support).path), detail)
            XCTAssertTrue(detail.contains(bad.path), "names the override that was tried")
            XCTAssertTrue(detail.contains("missing"), detail)
            XCTAssertTrue(detail.contains(QwenANEModelLocation.environmentKey), detail)
        }
    }

    func testAHalfCopiedSetIsNotAcceptedAndNamesTheMissingPiece() throws {
        let dir = try tempDir()
        try fakeModelSet(at: dir)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("coreml/upMall.mlmodelc"))
        XCTAssertEqual(QwenANEModelLocation.missingEntry(in: dir), "coreml/upMall.mlmodelc")
    }

    func testProviderThrowsModelNotInstalledBeforeLoadingAnything() async throws {
        // No env override, empty defaults: the real default path decides. Skip when the dev copy exists.
        if QwenANEModelLocation.missingEntry(in: QwenANEModelLocation.defaultDirectory()) == nil
            || ProcessInfo.processInfo.environment[QwenANEModelLocation.environmentKey] != nil { throw XCTSkip("a model set is installed here") }
        do {
            _ = try await MLXModelProvider().loadModel(backend: .qwen06BANE)
            XCTFail("expected modelNotInstalled")
        } catch EngineError.modelNotInstalled(let backend, _) {
            XCTAssertEqual(backend, .qwen06BANE)
        }
    }

    // MARK: references

    private func wav(seconds: Double) -> Data {
        let n = Int(seconds * 24_000)
        var pcm = Data()
        for i in 0..<n { var v = Int16(Float(sin(Double(i) * 0.05)) * 8000).littleEndian; withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) } }
        return WAVWriterData.wav(pcm: pcm)
    }

    // MARK: long lines

    @available(macOS 15.0, iOS 18.0, *)
    func testALineThatFitsIsOneRenderAndALongOneSplitsAtSentences() {
        let short = "Good evening, and welcome back to the late show."
        XCTAssertEqual(QwenANESpeechModel.parts(short, fits: { _ in true }), [short])
        let sentence = "That was a slow one, and there is another just like it coming up after the news. "
        let long = String(repeating: sentence, count: 6)
        let parts = QwenANESpeechModel.parts(long, fits: { $0.count < 200 })
        XCTAssertGreaterThan(parts.count, 1)
        for p in parts {
            XCTAssertLessThanOrEqual(LongTextChunker.estimatedSeconds(p), QwenANESpeechModel.partSeconds)
            XCTAssertTrue(p.trimmingCharacters(in: .whitespaces).hasSuffix("."), p)
        }
        XCTAssertEqual(parts.joined().filter { !$0.isWhitespace }, long.filter { !$0.isWhitespace },
                       "every word is spoken once, in order")
    }

    /// With a model set installed (GLOAM_QWEN_ANE_MODELS), a line too long for one render comes back whole:
    /// every part rendered through one session, not cut at the talker's window.
    @available(macOS 15.0, iOS 18.0, *)
    func testALongLineRendersEveryPart() async throws {
        // ~60 s of Benson rendered for real: minutes in a debug build. Opt in with QWEN_SLOW_TESTS=1.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["QWEN_SLOW_TESTS"] == "1",
                          "slow real-model test: set QWEN_SLOW_TESTS=1 to run it")
        guard let p = ProcessInfo.processInfo.environment[QwenANEModelLocation.environmentKey], !p.isEmpty else {
            throw XCTSkip("\(QwenANEModelLocation.environmentKey) is not set")
        }
        let models = URL(fileURLWithPath: p)
        // Benson, the pack the repo ships: its master and transcript, its stored Qwen section beside them.
        let pack = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../packs/benson.gvoice").standardizedFileURL
        let dir = try tempDir()
        let unzip = try Process.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", pack.path, dir.path])
        unzip.waitUntilExit()
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("manifest.json"))) as? [String: Any]
        let base = (manifest?["source"] as? [String: Any])?["base"] as? [String: Any]
        let refText = try XCTUnwrap(base?["text"] as? String)
        let ref = dir.appendingPathComponent("ref.wav")
        try FileManager.default.copyItem(at: dir.appendingPathComponent("source/ref.wav"), to: ref)
        let model = try await Task.detached { try QwenANESpeechModel(modelsDirectory: models, cacheRoot: dir.appendingPathComponent("cache")) }.value
        let sentence = "That was a slow one, and there is another just like it coming up after the news. "
        let text = String(repeating: sentence, count: 12)
        let samples = try await model.synthesize(ProviderRequest(text: text, refAudioPath: ref.path, refText: refText, seed: 3))
        // ~12 x 5 s of speech; one render would stop at the window, well short of it.
        XCTAssertGreaterThan(Double(samples.count) / 24000, 40)
    }

    @available(macOS 15.0, iOS 18.0, *)
    func testReferenceOverTheEncoderInputGetsAWindowInsteadOfARefusal() async throws {
        let dir = try tempDir()
        let ref = dir.appendingPathComponent("ref.wav")
        try wav(seconds: 50).write(to: ref)
        // A 50 s master with no stored window: a section of it is picked, and prep moves on to the encoders,
        // which this empty set lacks. A refusal for length would be a different error. Off the main thread,
        // as the render queue is: the recognizer reports back on the main queue, which prep blocks on.
        do {
            _ = try await Task.detached {
                try QwenANESpeechModel.prepare(reference: ref, transcript: "some words of the master",
                                               modelsDirectory: dir, cacheRoot: dir.appendingPathComponent("cache"))
            }.value
            XCTFail("an empty model set cannot prepare a voice")
        } catch EngineError.generationFailed(_, let message) {
            XCTAssertTrue(message.contains("QwenSpeechEncoder"), message)
        }
        // The section was chosen at prep time and stored in the voice's own qwen3-0.6b folder.
        let window = dir.appendingPathComponent("engines/qwen3-0.6b/ref.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: window.path))
        let file = try AVAudioFile(forReading: window)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        XCTAssertLessThanOrEqual(seconds, 30.0)
        XCTAssertGreaterThan(seconds, 15.0)
    }
}

private enum WAVWriterData {
    static func wav(pcm: Data) -> Data {
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var d = Data("RIFF".utf8); d += le(UInt32(36 + pcm.count)); d += Data("WAVEfmt ".utf8)
        d += le(UInt32(16)); d += le(UInt16(1)); d += le(UInt16(1)); d += le(UInt32(24_000)); d += le(UInt32(48_000))
        d += le(UInt16(2)); d += le(UInt16(16)); d += Data("data".utf8); d += le(UInt32(pcm.count)); d += pcm
        return d
    }
}
