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
        // The window that went to the encoder: the voice's own (transcribed) or the cached slice.
        let candidates = [dir.appendingPathComponent("engines/lux-tts/ref.wav")]
            + ((try? FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("cache/windows"),
                                                             includingPropertiesForKeys: nil)) ?? [])
        let window = try XCTUnwrap(candidates.first { FileManager.default.fileExists(atPath: $0.path) })
        let file = try AVAudioFile(forReading: window)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        XCTAssertLessThanOrEqual(seconds, 30.0)
        XCTAssertGreaterThan(seconds, 15.0)
    }

    @available(macOS 15.0, iOS 18.0, *)
    func testLongReferenceUsesTheVoicesLuxWindowAndItsTranscript() throws {
        let dir = try tempDir()
        let ref = dir.appendingPathComponent("ref.wav")
        try wav(seconds: 40).write(to: ref)
        let engines = dir.appendingPathComponent("engines/lux-tts")
        try FileManager.default.createDirectory(at: engines, withIntermediateDirectories: true)
        try wav(seconds: 12).write(to: engines.appendingPathComponent("ref.wav"))
        let meta = #"{"audio":"engines/lux-tts/ref.wav","text":"the words of the window"}"#
        try Data(meta.utf8).write(to: engines.appendingPathComponent("voice.json"))
        // The window is accepted (it fits), so prep moves on to the encoders, which this empty set lacks.
        XCTAssertThrowsError(try QwenANESpeechModel.prepare(reference: ref, transcript: "text of the whole 40 s master",
                                                            modelsDirectory: dir, cacheRoot: dir.appendingPathComponent("cache"))) { error in
            guard case EngineError.generationFailed(_, let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("QwenSpeechEncoder"), message)
        }
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
