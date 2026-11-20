import MLX
import MLXNN
import MLXRandom
import XCTest

@testable import EngineKit

/// MLX peak memory of one LuxTTS acoustic-model sample at a phone-sized chunk
/// (Billie Frost's 1062-frame / 188-token reference + 2016 generated frames, a
/// 336-char chunk), on this Mac's Metal allocator -- the same allocator and
/// counters the iPhone build logs ([luxmem]). Values don't matter for memory,
/// so tokens and prompt features are synthetic.
///
/// Opt-in: TEST_RUNNER_LUXMEM_BENCH=1, weights from TEST_RUNNER_LUXTTS_WEIGHTS_DIR.
final class LuxMemoryBenchTests: XCTestCase {
    func testAcousticModelPeak() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["LUXMEM_BENCH"] == "1", "set TEST_RUNNER_LUXMEM_BENCH=1")
        let dir = URL(fileURLWithPath: try XCTUnwrap(env["LUXTTS_WEIGHTS_DIR"]))

        let model = ZipVoiceDistill(config: LuxTTSConfig())
        var weights = try loadArrays(url: dir.appendingPathComponent("lux_model.safetensors"))
        for key in Array(weights.keys) {
            let renamed = key
                .replacingOccurrences(of: ".time_embed.0.", with: ".time_embed.linear1.")
                .replacingOccurrences(of: ".time_embed.2.", with: ".time_embed.linear2.")
                .replacingOccurrences(of: ".time_emb.1.", with: ".time_emb.linear.")
            if renamed != key { weights[renamed] = weights.removeValue(forKey: key) }
        }
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        weights = [:]
        eval(model)  // MLX.eval: materialise the weights
        Memory.clearCache()
        if let mb = Int(env["LUXMEM_CACHE_MB"] ?? "") { Memory.cacheLimit = mb * 1_000_000 }

        let promptFrames = Int(env["LUXMEM_PROMPT_FRAMES"] ?? "") ?? 1062
        let promptTokenCount = Int(env["LUXMEM_PROMPT_TOKENS"] ?? "") ?? 188
        let genFrames = Int(env["LUXMEM_GEN_FRAMES"] ?? "") ?? 2016
        // .predict sizes the output as promptFrames/promptTokens x textTokens.
        let textTokenCount = Int((Double(genFrames) * Double(promptTokenCount)
            / Double(promptFrames)).rounded())
        let tokens = (0 ..< textTokenCount).map { 1 + $0 % 300 }
        let promptTokens = (0 ..< promptTokenCount).map { 1 + ($0 * 7) % 300 }
        let promptFeatures = MLXRandom.normal([1, promptFrames, 100]) * 0.3
        eval(promptFeatures)

        for run in 0 ..< (Int(env["LUXMEM_RUNS"] ?? "") ?? 2) {
            Memory.clearCache()
            let base = Memory.activeMemory
            Memory.peakMemory = 0
            let started = Date()
            let out = model.sample(
                tokens: [tokens], promptTokens: [promptTokens],
                promptFeatures: promptFeatures, promptFeaturesLens: [promptFrames],
                duration: .predict, numSteps: 4, guidanceScale: 3.0, tShift: 0.5,
                speed: 1.0, durationPadFrames: 16)
            eval(out.features)
            if env["LUXMEM_FOOTPRINT"] == "1" {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/footprint")
                task.arguments = ["\(ProcessInfo.processInfo.processIdentifier)"]
                let pipe = Pipe()
                task.standardOutput = pipe
                try task.run()
                task.waitUntilExit()
                let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                for line in text.split(separator: "\n").prefix(25) { print("FOOTPRINT \(line)") }
            }
            print(String(
                format: "LUXMEM run %d: frames %d + prompt %d, weights %d MB, transient peak %d MB, cache after %d MB, %.2fs",
                run, out.features.dim(1), promptFrames, base / 1_000_000,
                (Memory.peakMemory - base) / 1_000_000, Memory.cacheMemory / 1_000_000,
                Date().timeIntervalSince(started)))
        }
    }
}
