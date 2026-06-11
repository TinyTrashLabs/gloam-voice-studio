import XCTest
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

final class GloamEngineTests: XCTestCase {
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
