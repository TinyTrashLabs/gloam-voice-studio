import XCTest
import MLXLMCommon
@testable import EngineKit

final class FakeModel: SpeechModel, @unchecked Sendable {
    let sampleRate: Int
    var received: [ProviderRequest] = []
    var samplesToReturn: [Float]
    var errorToThrow: Error?

    init(sampleRate: Int = 24000, samples: [Float] = [0.1, 0.2, 0.3]) {
        self.sampleRate = sampleRate
        self.samplesToReturn = samples
    }

    func synthesize(_ request: ProviderRequest) async throws -> [Float] {
        if let errorToThrow { throw errorToThrow }
        received.append(request)
        return samplesToReturn
    }
}

final class FakeProvider: ModelProviding, @unchecked Sendable {
    var loads: [BackendID] = []
    var evictions = 0
    var models: [BackendID: any SpeechModel] = [:]

    func loadModel(backend: BackendID) async throws -> any SpeechModel {
        loads.append(backend)
        let model = models[backend] ?? FakeModel()
        models[backend] = model
        return model
    }

    func didEvictModel() { evictions += 1 }
}

/// Detects concurrent entries into synthesize using a lock.
final class OverlapDetectingModel: SpeechModel, @unchecked Sendable {
    let sampleRate: Int = 24000
    private let lock = NSLock()
    private var current = 0
    private(set) var maxConcurrent = 0

    func synthesize(_ request: ProviderRequest) async throws -> [Float] {
        lock.withLock {
            current += 1
            maxConcurrent = max(maxConcurrent, current)
        }
        try await Task.sleep(for: .milliseconds(20))
        lock.withLock { current -= 1 }
        return [0.1, 0.2, 0.3]
    }
}

final class ChunkedFakeModel: SpeechModel, @unchecked Sendable {
    let sampleRate = 24_000

    func synthesize(_ request: ProviderRequest) async throws -> [Float] {
        [0.1, 0.2, 0.3, 0.4]
    }

    func synthesizeStream(_ request: ProviderRequest) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            continuation.yield([0.1, 0.2])
            continuation.yield([0.3, 0.4])
            continuation.finish()
        }
    }
}

final class GloamEngineTests: XCTestCase {
    func testSynthesisStreamPreservesProviderChunksAndSampleRate() async throws {
        let provider = FakeProvider()
        provider.models[.qwen06BMobile] = ChunkedFakeModel()
        let engine = GloamEngine(provider: provider)

        var chunks: [SynthesisChunk] = []
        for try await chunk in await engine.synthesizeStream(
            backend: .qwen06BMobile,
            request: SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav"))
        {
            chunks.append(chunk)
        }

        XCTAssertEqual(chunks.map(\.samples), [[0.1, 0.2], [0.3, 0.4]])
        XCTAssertEqual(chunks.map(\.sampleRate), [24_000, 24_000])
    }

    func testFishWithoutAckThrows() async {
        let engine = GloamEngine(provider: FakeProvider())
        do {
            _ = try await engine.synthesize(
                backend: .fishS2Pro, request: SynthesisRequest(text: "hi"))
            XCTFail("expected licenseAckRequired")
        } catch {
            XCTAssertEqual(error as? EngineError, .licenseAckRequired(.fishS2Pro))
        }
    }

    func testFishAfterAckSynthesizes() async throws {
        let provider = FakeProvider()
        let engine = GloamEngine(provider: provider)
        await engine.acknowledgeLicense(for: .fishS2Pro)
        let result = try await engine.synthesize(
            backend: .fishS2Pro, request: SynthesisRequest(text: "hi"))
        XCTAssertEqual(result.samples, [0.1, 0.2, 0.3])
        XCTAssertEqual(provider.loads, [.fishS2Pro])
    }

    func testBreezeWithoutAckThrows() async {
        let provider = FakeProvider()
        let engine = GloamEngine(provider: provider)
        do {
            _ = try await engine.synthesize(
                backend: .breezeTTS2, request: SynthesisRequest(text: "hi"))
            XCTFail("expected licenseAckRequired")
        } catch {
            XCTAssertEqual(error as? EngineError, .licenseAckRequired(.breezeTTS2))
        }
        XCTAssertTrue(provider.loads.isEmpty, "the gate runs before any weights load")
    }

    func testBreezeLongLineSynthesizesInPiecesJoinedByAGap() async throws {
        let provider = FakeProvider()
        let model = FakeModel(samples: [0.5])
        provider.models[.breezeTTS2] = model
        let engine = GloamEngine(provider: provider)
        await engine.acknowledgeLicense(for: .breezeTTS2)
        let text = String(repeating: "A long sentence goes right here. ", count: 120)
        let result = try await engine.synthesize(
            backend: .breezeTTS2, request: SynthesisRequest(text: text))
        XCTAssertGreaterThan(model.received.count, 1)
        let gap = GloamEngine.passGap(sampleRate: model.sampleRate).count
        XCTAssertEqual(result.samples.count, model.received.count + gap * (model.received.count - 1))
        // No reference (design): every later pass clones the first one, so
        // the line keeps one speaker. The anchor file is cleaned up after.
        let first = model.received[0]
        XCTAssertNil(first.refAudioPath)
        for later in model.received.dropFirst() {
            XCTAssertEqual(later.refText, first.text)
            XCTAssertNotNil(later.refAudioPath)
        }
        let anchor = try XCTUnwrap(model.received.last?.refAudioPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: anchor))
    }

    func testFishAckDoesNotUnlockBreeze() async {
        // Distinct licenses: one ack must never unlock the other.
        let engine = GloamEngine(provider: FakeProvider())
        await engine.acknowledgeLicense(for: .fishS2Pro)
        do {
            _ = try await engine.synthesize(
                backend: .breezeTTS2, request: SynthesisRequest(text: "hi"))
            XCTFail("expected licenseAckRequired")
        } catch {
            XCTAssertEqual(error as? EngineError, .licenseAckRequired(.breezeTTS2))
        }
    }

    func testValidationRunsBeforeModelLoad() async {
        // chatterbox with no ref must fail WITHOUT loading 2 GB of weights.
        let provider = FakeProvider()
        let engine = GloamEngine(provider: provider)
        _ = try? await engine.synthesize(
            backend: .chatterbox, request: SynthesisRequest(text: "hi"))
        XCTAssertEqual(provider.loads, [])
    }

    func testModelReusedForSameBackend() async throws {
        let provider = FakeProvider()
        let engine = GloamEngine(provider: provider)
        let req = SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav")
        _ = try await engine.synthesize(backend: .chatterboxTurbo, request: req)
        _ = try await engine.synthesize(backend: .chatterboxTurbo, request: req)
        XCTAssertEqual(provider.loads, [.chatterboxTurbo])  // loaded once
        XCTAssertEqual(provider.evictions, 0)
    }

    func testSwitchingBackendEvictsResident() async throws {
        let provider = FakeProvider()
        let engine = GloamEngine(provider: provider)
        await engine.acknowledgeLicense(for: .fishS2Pro)
        let req = SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav")
        _ = try await engine.synthesize(backend: .chatterboxTurbo, request: req)
        _ = try await engine.synthesize(backend: .fishS2Pro, request: req)
        XCTAssertEqual(provider.loads, [.chatterboxTurbo, .fishS2Pro])
        XCTAssertEqual(provider.evictions, 1)
        let loaded = await engine.loadedBackend()
        XCTAssertEqual(loaded, .fishS2Pro)
    }

    func testUnloadDropsResident() async throws {
        let provider = FakeProvider()
        let engine = GloamEngine(provider: provider)
        let req = SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav")
        _ = try await engine.synthesize(backend: .chatterboxTurbo, request: req)
        await engine.unload()
        XCTAssertEqual(provider.evictions, 1)
        let loaded = await engine.loadedBackend()
        XCTAssertNil(loaded)
    }

    func testUnloadWhenEmptyIsNoOp() async {
        let provider = FakeProvider()
        let engine = GloamEngine(provider: provider)
        await engine.unload()
        XCTAssertEqual(provider.evictions, 0)
    }

    func testSpeedAppliedToOutput() async throws {
        let provider = FakeProvider()
        provider.models[.chatterboxTurbo] = FakeModel(samples: [Float](repeating: 0.5, count: 1000))
        let engine = GloamEngine(provider: provider)
        let result = try await engine.synthesize(
            backend: .chatterboxTurbo,
            request: SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav", speed: 2.0))
        XCTAssertEqual(result.samples.count, 500)
    }

    func testGenerationFailureWrapped() async throws {
        let provider = FakeProvider()
        let failing = FakeModel()
        failing.errorToThrow = EngineError.generationFailed(backend: .chatterboxTurbo, message: "boom")
        provider.models[.chatterboxTurbo] = failing
        let engine = GloamEngine(provider: provider)
        do {
            _ = try await engine.synthesize(
                backend: .chatterboxTurbo,
                request: SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav"))
            XCTFail("expected error")
        } catch let error as EngineError {
            XCTAssertEqual(error, .generationFailed(backend: .chatterboxTurbo, message: "boom"))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
        // A failed generation must not wedge the engine: same backend still usable.
        failing.errorToThrow = nil
        let result = try await engine.synthesize(
            backend: .chatterboxTurbo,
            request: SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav"))
        XCTAssertFalse(result.samples.isEmpty)
    }

    func testResultCarriesModelSampleRate() async throws {
        let provider = FakeProvider()
        provider.models[.fishS2Pro] = FakeModel(sampleRate: 44100)
        let engine = GloamEngine(provider: provider)
        await engine.acknowledgeLicense(for: .fishS2Pro)
        let result = try await engine.synthesize(
            backend: .fishS2Pro, request: SynthesisRequest(text: "hi"))
        XCTAssertEqual(result.sampleRate, 44100)
    }

    func testConcurrentSynthesizeForSameBackendLoadsOnce() async throws {
        let provider = FakeProvider()
        let overlapModel = OverlapDetectingModel()
        provider.models[.chatterboxTurbo] = overlapModel
        let engine = GloamEngine(provider: provider)
        let req = SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav")
        async let r1 = engine.synthesize(backend: .chatterboxTurbo, request: req)
        async let r2 = engine.synthesize(backend: .chatterboxTurbo, request: req)
        async let r3 = engine.synthesize(backend: .chatterboxTurbo, request: req)
        async let r4 = engine.synthesize(backend: .chatterboxTurbo, request: req)
        _ = try await (r1, r2, r3, r4)
        // Model was pre-installed; provider should have loaded it at most once.
        XCTAssertLessThanOrEqual(provider.loads.filter { $0 == .chatterboxTurbo }.count, 1)
    }

    func testGenerationIsSerialized() async throws {
        let provider = FakeProvider()
        let overlapModel = OverlapDetectingModel()
        provider.models[.chatterboxTurbo] = overlapModel
        let engine = GloamEngine(provider: provider)
        let req = SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav")
        async let r1 = engine.synthesize(backend: .chatterboxTurbo, request: req)
        async let r2 = engine.synthesize(backend: .chatterboxTurbo, request: req)
        async let r3 = engine.synthesize(backend: .chatterboxTurbo, request: req)
        async let r4 = engine.synthesize(backend: .chatterboxTurbo, request: req)
        _ = try await (r1, r2, r3, r4)
        XCTAssertEqual(overlapModel.maxConcurrent, 1)
    }
}


// MARK: - Audio8 streaming (model-backed; skipped unless AUDIO8_MODEL_DIR is set)

final class Audio8StreamingTests: XCTestCase {
    private static var refWav: String { ProcessInfo.processInfo.environment["AUDIO8_REF_WAV"] ?? "" }
    private static var refText: String { ProcessInfo.processInfo.environment["AUDIO8_REF_TEXT"] ?? "" }
    private static let line = "Welcome back to the late show. Tonight we have a long list of songs for you, and a few stories about the people who made them. Pour yourself something warm, settle in, and stay awhile, because we are not going anywhere."

    private func loadModel() async throws -> any SpeechModel {
        guard let dir = ProcessInfo.processInfo.environment["AUDIO8_MODEL_DIR"], !dir.isEmpty else {
            throw XCTSkip("set AUDIO8_MODEL_DIR to run Audio8 model-backed tests")
        }
        try XCTSkipUnless(!Self.refWav.isEmpty && !Self.refText.isEmpty
                          && FileManager.default.fileExists(atPath: Self.refWav),
                          "set AUDIO8_REF_WAV and AUDIO8_REF_TEXT (reference clip and its exact transcript)")
        let provider = MLXModelProvider(modelPathResolver: { $0 == .audio8 ? dir : nil })
        return try await provider.loadModel(backend: .audio8)
    }

    private var request: ProviderRequest {
        ProviderRequest(text: Self.line, refAudioPath: Self.refWav, refText: Self.refText,
                        temperature: 0.7, topP: 0.8, seed: 7)
    }

    func testAudio8StreamsMoreThanOneChunk() async throws {
        let model = try await loadModel()
        let start = Date()
        var arrivals: [Double] = []
        var total = 0
        for try await chunk in model.synthesizeStream(request) {
            arrivals.append(Date().timeIntervalSince(start))
            total += chunk.count
        }
        let wall = Date().timeIntervalSince(start)
        print("AUDIO8 stream: chunks=\(arrivals.count) first=\(arrivals.first ?? -1)s wall=\(wall)s audio=\(Double(total) / Double(model.sampleRate))s")
        XCTAssertGreaterThanOrEqual(arrivals.count, 3)
        XCTAssertLessThan(arrivals.first ?? .infinity, wall * 0.4,
                          "first chunk must land before 40% of wall time (arrivals \(arrivals), wall \(wall))")
    }

    func testAudio8ParameterMappingIsSharedAndExposesOnlyTempTopPSeed() {
        var base = GenerateParameters(maxTokens: 100, temperature: 0.5, topP: 0.9, topK: 40)
        base.repetitionPenalty = 1.1
        let request = ProviderRequest(text: "x", temperature: 0.8, topP: 0.7, topK: 5,
                                      repetitionPenalty: 1.5, seed: 9)
        let p = MLXSpeechModel.audio8Parameters(request, base: base)
        XCTAssertEqual(p.temperature, 0.8)
        XCTAssertEqual(p.topP, 0.7)
        XCTAssertEqual(p.seed, 9)
        XCTAssertEqual(p.topK, 40, "topK is not exposed for Audio8")
        XCTAssertEqual(p.repetitionPenalty, 1.1, "repetition penalty is not exposed for Audio8")
        let untouched = MLXSpeechModel.audio8Parameters(ProviderRequest(text: "x"), base: base)
        XCTAssertEqual(untouched.temperature, 0.5)
        XCTAssertEqual(untouched.topP, 0.9)
    }

    func testAudio8SynthesizeConcatenatesTheStream() async throws {
        let model = try await loadModel()
        let samples = try await model.synthesize(request)
        XCTAssertGreaterThan(samples.count, model.sampleRate * 3)
    }

    func testAudio8StreamCancelStopsPromptly() async throws {
        let model = try await loadModel()
        let stream = model.synthesizeStream(request)
        let firstSeen = expectation(description: "first chunk")
        let finishedAt = Box<Date?>(nil)
        let afterCancel = Box(0)
        let cancelledAt = Box<Date?>(nil)
        let consumer = Task {
            do {
                for try await _ in stream {
                    if cancelledAt.value != nil { afterCancel.value += 1 }
                    if finishedAt.value == nil, cancelledAt.value == nil { firstSeen.fulfill() }
                    try Task.checkCancellation()
                }
            } catch {}
            finishedAt.value = Date()
        }
        await fulfillment(of: [firstSeen], timeout: 120)
        cancelledAt.value = Date()
        consumer.cancel()
        await consumer.value
        let elapsed = finishedAt.value!.timeIntervalSince(cancelledAt.value!)
        XCTAssertLessThan(elapsed, 1.0, "stream must finish within 1 s of cancel")
        XCTAssertLessThanOrEqual(afterCancel.value, 1, "no further chunks after cancel")
        // Producer side: the generating task itself ended within 1 s of the cancel.
        let speech = try XCTUnwrap(model as? MLXSpeechModel)
        let deadline = Date().addingTimeInterval(1.0)
        while speech.audio8ActiveGenerations.value > 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(speech.audio8ActiveGenerations.value, 0, "generation still running 1 s after cancel")
        // GPU is free again: a short render completes right away.
        let t0 = Date()
        let again = try await model.synthesize(ProviderRequest(text: "Hello there.", refAudioPath: Self.refWav,
                                                               refText: Self.refText, seed: 1))
        XCTAssertFalse(again.isEmpty)
        let seconds = Double(again.count) / Double(model.sampleRate)
        XCTAssertLessThan(Date().timeIntervalSince(t0), max(10, seconds * 8), "follow-up render was starved by a leaked generation")
    }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _v: T
    init(_ v: T) { _v = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _v }
        set { lock.lock(); defer { lock.unlock() }; _v = newValue }
    }
}
