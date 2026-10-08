import XCTest
@testable import GloamVoiceEditing

final class AppleVoiceIsolationTests: XCTestCase {
    /// Offline render: same length as the input, sample-aligned, never touching the audio hardware.
    func testIsolationKeepsLengthAndRunsOffline() throws {
        guard AppleVoiceIsolation.isAvailable else { throw XCTSkip("AUSoundIsolation HQ Voice needs macOS 15 / iOS 18") }
        var x = [Float](repeating: 0, count: 24_000)
        for i in x.indices { x[i] = 0.2 * sin(Float(i) * 2 * .pi * 220 / 24_000) + Float.random(in: -0.02...0.02) }
        let out = try AppleVoiceIsolation.isolate(x, sampleRate: 24_000)
        XCTAssertEqual(out.count, x.count)
        XCTAssertTrue(out.allSatisfy { $0.isFinite })
    }

    func testEmptyInputIsEmpty() throws {
        XCTAssertEqual(try AppleVoiceIsolation.isolate([], sampleRate: 24_000), [])
    }

    func testStandardDenoiserFallsBackWhenTheFirstThrows() async throws {
        struct Broken: SpeechDenoiser { let name = "broken"; func denoise(_ s: [Float]) async throws -> [Float] { throw CancellationError() } }
        struct Echo: SpeechDenoiser { let name = "echo"; func denoise(_ s: [Float]) async throws -> [Float] { s } }
        let d = FallbackDenoiser(first: Broken(), second: Echo())
        let out = try await d.denoise([0.1, 0.2])
        XCTAssertEqual(out, [0.1, 0.2])
        XCTAssertEqual(d.name, "broken, else echo")
        XCTAssertNotNil(NoiseCleanup.standardDenoiser(fallback: Echo()), "a fallback alone is still a cleaner")
    }
}
