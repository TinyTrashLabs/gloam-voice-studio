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
    private func fakeModelSet(at dir: URL, set: QwenANEModelSet = .qwen06) throws {
        for entry in set.requiredFiles {
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
        XCTAssertEqual(b.surfaces, [.studio, .chatVoice, .apiServer, .downloadable])
        XCTAssertTrue(BackendID.on(.studio).contains(b))
        XCTAssertTrue(BackendID.on(.chatVoice).contains(b))
        XCTAssertEqual(b.spec.modelRepo, "tinytrashlabs/Qwen3-TTS-0.6B-Base-ANE")
        XCTAssertEqual(b.modelRepo(quant: nil), "tinytrashlabs/Qwen3-TTS-0.6B-Base-ANE")
        XCTAssertEqual(b.modelRepo(quant: .q4), "tinytrashlabs/Qwen3-TTS-0.6B-Base-ANE", "one fixed set, no precisions")
        XCTAssertEqual(b.diskFolder(quantRaw: nil), QwenANEModelLocation.folderName)
        XCTAssertTrue(b.sharesFolderWithUser)
        XCTAssertFalse(BackendID.qwen06BMobile.sharesFolderWithUser)
        XCTAssertEqual(b.availableQuants, [])
    }

    // MARK: the 1.7B build shares every rule with the 0.6B one

    func testBackend17BDeclaration() {
        let b = BackendID.qwen17BANE
        XCTAssertEqual(b.rawValue, "qwen3-1.7b-ane")
        XCTAssertTrue(b.isQwenANE); XCTAssertTrue(BackendID.qwen06BANE.isQwenANE)
        XCTAssertFalse(BackendID.qwen17B.isQwenANE)
        XCTAssertFalse(b.isQwen)
        XCTAssertEqual(b.qwenANEKind, .qwen17); XCTAssertEqual(BackendID.qwen06BANE.qwenANEKind, .qwen06)
        XCTAssertNil(BackendID.qwen17B.qwenANEKind)
        XCTAssertEqual(b.speechFamily, .neuralEngine)
        XCTAssertEqual(b.controls, BackendID.qwen06BANE.controls)
        XCTAssertEqual(b.surfaces, BackendID.qwen06BANE.surfaces)
        XCTAssertTrue(b.needsRefText); XCTAssertTrue(b.spec.needsRefAudio)
        XCTAssertEqual(b.spec.modelRepo, "tinytrashlabs/Qwen3-TTS-1.7B-Base-ANE")
        XCTAssertEqual(b.diskFolder(quantRaw: nil), QwenANEModelSet.qwen17.folderName)
        XCTAssertEqual(b.availableQuants, [])
        XCTAssertTrue(b.sharesFolderWithUser)
        XCTAssertEqual(b.emotionMechanism, BackendID.qwen06BANE.emotionMechanism)
        XCTAssertEqual(b.displayName, "Qwen 1.7B ANE")
        XCTAssertEqual(BackendID(rawValue: "qwen3-1.7b-ane"), .qwen17BANE)
    }

    func testPlanner17BRequiresAReferenceAndKeepsTheNeuralKnobs() throws {
        XCTAssertThrowsError(try RequestPlanner.plan(backend: .qwen17BANE, request: SynthesisRequest(text: "hi"))) {
            XCTAssertEqual($0 as? EngineError, .refAudioRequired(.qwen17BANE))
        }
        var r = SynthesisRequest(text: "hi", refAudioPath: "/tmp/x.wav", refText: "hello")
        r.firstChunkFrames = 4; r.talkSession = "reply-1"
        for b in [BackendID.qwen06BANE, .qwen17BANE] {
            let p = try RequestPlanner.plan(backend: b, request: r)
            XCTAssertEqual(p.firstChunkFrames, 4, b.rawValue); XCTAssertEqual(p.talkSession, "reply-1", b.rawValue)
        }
        XCTAssertNil(try RequestPlanner.plan(backend: .qwen17B, request: r).talkSession)
    }

    func testModelSetsResolveSeparately() throws {
        let support = try tempDir()
        let defaults = isolatedDefaults()
        XCTAssertNotEqual(QwenANEModelSet.qwen17.environmentKey, QwenANEModelSet.qwen06.environmentKey)
        XCTAssertNotEqual(QwenANEModelSet.qwen17.defaultsKey, QwenANEModelSet.qwen06.defaultsKey)
        XCTAssertEqual(QwenANEModelSet.of(.qwen17BANE), .qwen17); XCTAssertEqual(QwenANEModelSet.of(.qwen06BANE), .qwen06)
        XCTAssertNil(QwenANEModelSet.of(.qwen17B))
        XCTAssertEqual(QwenANEModelSet.qwen17.defaultDirectory(models: support).path, support.path + "/qwen3-1.7b-ane",
                       "installed in the shared Models folder")
        XCTAssertEqual(QwenANEModelSet.qwen17.legacyDirectory(appSupport: support).path,
                       support.path + "/GloamVoiceStudio/Models/qwen3-1.7b-ane")
        XCTAssertEqual(QwenANEModelSet.qwen17.defaultCacheRoot(appSupport: support).path,
                       support.path + "/GloamVoiceStudio/Cache/qwen3-1.7b-ane")
        // a complete 0.6B set is not a 1.7B set (two talker chunks, no cp_in_proj) and the other way round
        try fakeModelSet(at: QwenANEModelSet.qwen06.defaultDirectory(models: support), set: .qwen06)
        XCTAssertNotNil(try? QwenANEModelSet.qwen06.resolve(environment: [:], defaults: defaults, appSupport: support, models: support))
        XCTAssertThrowsError(try QwenANEModelSet.qwen17.resolve(environment: [:], defaults: defaults, appSupport: support, models: support)) {
            guard case .modelNotInstalled(let backend, let detail) = $0 as? EngineError else { return XCTFail("\($0)") }
            XCTAssertEqual(backend, .qwen17BANE)
            XCTAssertTrue(detail.contains("GLOAM_QWEN_ANE_17B_MODELS"), detail)
        }
        try fakeModelSet(at: QwenANEModelSet.qwen17.defaultDirectory(models: support), set: .qwen17)
        XCTAssertNotNil(try? QwenANEModelSet.qwen17.resolve(environment: [:], defaults: defaults, appSupport: support, models: support))
        let only17 = try tempDir()
        try fakeModelSet(at: QwenANEModelSet.qwen17.defaultDirectory(models: only17), set: .qwen17)
        XCTAssertNil(try? QwenANEModelSet.qwen06.resolve(environment: [:], defaults: defaults, appSupport: only17, models: only17))
        XCTAssertEqual(QwenANEModelSet.qwen17.requiredFiles.filter { $0.contains("talker") }.count, 4)
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
        try fakeModelSet(at: QwenANEModelLocation.defaultDirectory(models: support))
        let defaults = isolatedDefaults()
        defaults.set(pref.path, forKey: QwenANEModelLocation.defaultsKey)

        XCTAssertEqual(try QwenANEModelLocation.resolve(environment: [QwenANEModelLocation.environmentKey: env.path],
                                                        defaults: defaults, appSupport: support, models: support).path, env.path)
        XCTAssertEqual(try QwenANEModelLocation.resolve(environment: [:], defaults: defaults, appSupport: support, models: support).path, pref.path)
        defaults.removeObject(forKey: QwenANEModelLocation.defaultsKey)
        XCTAssertEqual(try QwenANEModelLocation.resolve(environment: [:], defaults: defaults, appSupport: support, models: support).path,
                       QwenANEModelLocation.defaultDirectory(models: support).path)
    }

    func testDefaultLocationIsTheSharedModelsFolder() {
        XCTAssertEqual(QwenANEModelLocation.defaultDirectory(models: URL(fileURLWithPath: "/tmp/Group/Models")).path,
                       "/tmp/Group/Models/qwen3-0.6b-ane")
        XCTAssertEqual(QwenANEModelSet.qwen06.defaultDirectory().path,
                       StoragePaths.models.appendingPathComponent("qwen3-0.6b-ane").path, "beside the MLX models")
    }

    func testAnInstallInTheOldPerAppFolderStillResolves() throws {
        let support = try tempDir(), models = try tempDir()
        try fakeModelSet(at: QwenANEModelSet.qwen06.legacyDirectory(appSupport: support), set: .qwen06)
        XCTAssertEqual(try QwenANEModelSet.qwen06.resolve(environment: [:], defaults: isolatedDefaults(),
                                                          appSupport: support, models: models).path,
                       QwenANEModelSet.qwen06.legacyDirectory(appSupport: support).path)
        try fakeModelSet(at: QwenANEModelSet.qwen06.defaultDirectory(models: models), set: .qwen06)
        XCTAssertEqual(try QwenANEModelSet.qwen06.resolve(environment: [:], defaults: isolatedDefaults(),
                                                          appSupport: support, models: models).path,
                       QwenANEModelSet.qwen06.defaultDirectory(models: models).path, "the shared copy wins")
    }

    func testMissingModelSetNamesTheExpectedPath() throws {
        let support = try tempDir(), bad = try tempDir()
        XCTAssertThrowsError(try QwenANEModelLocation.resolve(
            environment: [QwenANEModelLocation.environmentKey: bad.path],
            defaults: isolatedDefaults(), appSupport: support, models: support)) { error in
            guard case EngineError.modelNotInstalled(let backend, let detail) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(backend, .qwen06BANE)
            XCTAssertTrue(detail.contains(QwenANEModelLocation.defaultDirectory(models: support).path), detail)
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
        if QwenANEModelLocation.candidates(environment: [:]).contains(where: { QwenANEModelLocation.missingEntry(in: $0) == nil })
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
