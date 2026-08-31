import XCTest
@testable import EngineKit

/// A scripted memory meter: each reading is whatever the test says it is, so a
/// load's measured cost is exact and independent of what the rest of the suite
/// is allocating.
private final class StubFootprint: @unchecked Sendable {
    private let lock = NSLock()
    private var readings: [Int64]
    init(_ readings: [Int64]) { self.readings = readings }
    /// Repeats the final reading once the script runs out, so a test only has
    /// to specify the readings it actually cares about.
    func next() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return readings.count > 1 ? readings.removeFirst() : (readings.first ?? 0)
    }
}

final class MeasuredFootprintTests: XCTestCase {
    private let req = SynthesisRequest(text: "hi", refAudioPath: "/tmp/r.wav")
    private let turbo = BackendID.chatterboxTurbo.rawValue

    private func engine(_ readings: [Int64],
                        provider: ModelProviding = FakeProvider()) -> GloamEngine {
        let stub = StubFootprint(readings)
        return GloamEngine(provider: provider, footprint: { stub.next() })
    }

    /// The number beside a model in the picker comes from the engine, not from
    /// whoever asked for the load — so a load triggered by synthesis (the
    /// Generate path) is measured exactly like a picker preload. This is the
    /// case the app-layer version missed.
    func testSynthesisLoadIsMeasured() async throws {
        let engine = engine([1_000_000_000, 3_000_000_000])
        _ = try await engine.synthesize(backend: .chatterboxTurbo, request: req)

        let measured = await engine.measuredFootprints()
        XCTAssertEqual(measured[turbo], 2_000_000_000)
    }

    func testPreloadIsMeasured() async throws {
        let engine = engine([1_000_000_000, 3_000_000_000])
        try await engine.preload(backend: .chatterboxTurbo)

        let measured = await engine.measuredFootprints()
        XCTAssertEqual(measured[turbo], 2_000_000_000)
    }

    /// An evicted model costs nothing, so it must stop reporting a cost —
    /// otherwise the picker keeps showing GB for something that isn't resident.
    func testEvictionForgetsTheMeasurement() async throws {
        let engine = engine([1_000_000_000, 3_000_000_000])
        try await engine.preload(backend: .chatterboxTurbo)
        let whileResident = await engine.measuredFootprints()
        XCTAssertNotNil(whileResident[turbo])

        await engine.unload()
        let afterEviction = await engine.measuredFootprints()
        XCTAssertNil(afterEviction[turbo], "an unloaded model must not report a cost")
    }

    /// A load whose window also frees memory records nothing rather than a
    /// figure that would understate the model by an arbitrary amount.
    func testLoadThatFreesMemoryRecordsNothing() async throws {
        let engine = engine([3_000_000_000, 2_000_000_000])
        try await engine.preload(backend: .chatterboxTurbo)

        let measured = await engine.measuredFootprints()
        XCTAssertNil(measured[turbo])
    }

    /// Noise below the floor isn't a model.
    func testTrivialGrowthIsBelowTheFloor() async throws {
        let engine = engine([1_000_000_000, 1_010_000_000])
        try await engine.preload(backend: .chatterboxTurbo)

        let measured = await engine.measuredFootprints()
        XCTAssertNil(measured[turbo])
    }

    /// Switching backends replaces the entry rather than accumulating: the old
    /// model is evicted by the load itself, so only the resident one has a cost.
    func testSwitchingBackendsLeavesOnlyTheResidentCost() async throws {
        let engine = engine([1_000_000_000, 3_000_000_000, 3_000_000_000, 4_000_000_000])
        try await engine.preload(backend: .chatterboxTurbo)
        try await engine.preload(backend: .qwen06B)

        let measured = await engine.measuredFootprints()
        XCTAssertNil(measured[turbo], "evicted by the second load")
        XCTAssertEqual(measured[BackendID.qwen06B.rawValue], 1_000_000_000)
    }
}
