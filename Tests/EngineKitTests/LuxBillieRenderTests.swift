import Foundation
import MLX
import XCTest

@testable import EngineKit

/// A same-noise render of one line, for by-ear A/B of a change between two
/// builds: LuxSpeechModel end to end (misaki G2P on the Mac, the dual-path
/// 48 kHz vocoder the app uses), noise seeded, written as 16-bit WAV.
///
/// Opt-in: TEST_RUNNER_LUXMEM_BILLIE_OUT=<wav>, TEST_RUNNER_LUXTTS_WEIGHTS_DIR,
/// TEST_RUNNER_LUXMEM_BILLIE_REF=<ref wav>, TEST_RUNNER_LUXMEM_BILLIE_REF_TEXT,
/// TEST_RUNNER_LUXMEM_BILLIE_TEXT=<file with the line>,
/// TEST_RUNNER_LUXMEM_HALF_WEIGHTS=1 for float16 weights / float32 compute.
final class LuxBillieRenderTests: XCTestCase {
    func testRenderSeededLine() async throws {
        let env = ProcessInfo.processInfo.environment
        let outPath = try XCTUnwrap(env["LUXMEM_BILLIE_OUT"].map { $0 }, "set TEST_RUNNER_LUXMEM_BILLIE_OUT")
        let dir = URL(fileURLWithPath: try XCTUnwrap(env["LUXTTS_WEIGHTS_DIR"]))
        let ref = try XCTUnwrap(env["LUXMEM_BILLIE_REF"])
        let refText = try XCTUnwrap(env["LUXMEM_BILLIE_REF_TEXT"])
        let text = try String(contentsOfFile: try XCTUnwrap(env["LUXMEM_BILLIE_TEXT"]), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Memory.cacheLimit = 0
        let half = env["LUXMEM_HALF_WEIGHTS"] == "1"
        let model = try await LuxSpeechModel.load(
            from: dir, phonemizer: try await MisakiPhonemizer.prepared(), leadInTrimming: false,
            acousticDType: half ? .float16 : .float32)
        MLXRandom.seed(UInt64(env["LUXMEM_SEED"] ?? "") ?? 7)
        let started = Date()
        let samples = try await model.synthesize(ProviderRequest(
            text: text, refAudioPath: ref, refText: refText, speed: 1.0,
            numSteps: 4, guidanceScale: 3.0, tShift: 0.5, returnSmooth: false))
        print(String(format: "LUXBILLIE %@: %.2f s audio, %.2f s, mlx peak %d MB",
                     outPath, Double(samples.count) / 48000, Date().timeIntervalSince(started),
                     Memory.peakMemory / 1_000_000))
        try Self.wav(samples, rate: 48000).write(to: URL(fileURLWithPath: outPath))
    }

    static func wav(_ samples: [Float], rate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
        return d
    }
}
