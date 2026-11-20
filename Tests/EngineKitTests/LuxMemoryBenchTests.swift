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
    /// fp32 vs a half-precision copy of the model on the same noise: memory,
    /// time, and how far the output features move. Opt-in like the above.
    func testHalfPrecisionCost() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["LUXMEM_BENCH"] == "1", "set TEST_RUNNER_LUXMEM_BENCH=1")
        let dir = URL(fileURLWithPath: try XCTUnwrap(env["LUXTTS_WEIGHTS_DIR"]))
        Memory.cacheLimit = 0
        let promptFrames = 1062, promptTokenCount = 188, genFrames = 2016
        let textTokenCount = Int((Double(genFrames) * Double(promptTokenCount) / Double(promptFrames)).rounded())
        let tokens = (0 ..< textTokenCount).map { 1 + $0 % 300 }
        let promptTokens = (0 ..< promptTokenCount).map { 1 + ($0 * 7) % 300 }
        MLXRandom.seed(11)
        let promptFeatures = MLXRandom.normal([1, promptFrames, 100]) * 0.3
        let total = 3095  // what .predict sizes this input to (2033 + 1062)
        let noise = MLXRandom.normal([1, total, 100])
        eval(promptFeatures, noise)

        var reference: MLXArray? = nil
        // (weights, compute): float16 weights with float32 compute is the
        // weights-only mode; (.float16, .float16) computes in half too.
        let modes: [(DType, DType)] = [(.float32, .float32), (.float16, .float32), (.float16, .float16)]
        for (wdtype, dtype) in modes {
            let model = try Self.loadModel(dir)
            if wdtype != .float32 {
                model.update(parameters: model.parameters().mapValues { $0.asType(wdtype) })
                eval(model)
            }
            Memory.clearCache()
            let base = Memory.activeMemory
            Memory.peakMemory = 0
            let started = Date()
            let out = model.sample(
                tokens: [tokens], promptTokens: [promptTokens],
                promptFeatures: promptFeatures.asType(dtype), promptFeaturesLens: [promptFrames],
                duration: .predict, numSteps: 4, guidanceScale: 3.0, tShift: 0.5,
                speed: 1.0, durationPadFrames: 16, noise: noise.asType(dtype))
            print("LUXHALF dtype out \(out.features.dtype)")
            let f = out.features.asType(.float32)
            eval(f)
            // LUXMEM_DUMP=<dir>: the features per mode, to diff two builds' arithmetic.
            if let dir = env["LUXMEM_DUMP"] {
                let data = f.asArray(Float.self).withUnsafeBufferPointer { Data(buffer: $0) }
                try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(wdtype)-\(dtype).f32"))
            }
            var err = Float(0)
            if let reference {
                err = (MLX.sqrt(MLX.mean(MLX.square(f - reference))) / MLX.sqrt(MLX.mean(MLX.square(reference)))).item(Float.self)
            } else { reference = f }
            print(String(format: "LUXHALF %@ weights / %@ compute: weights %d MB, transient peak %d MB, %.2fs, rel RMS err vs fp32 %.5f",
                         "\(wdtype)", "\(dtype)", base / 1_000_000, (Memory.peakMemory - base) / 1_000_000,
                         Date().timeIntervalSince(started), err))
        }
    }

    static func loadModel(_ dir: URL) throws -> ZipVoiceDistill {
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
        eval(model)  // MLX.eval: materialise the weights
        return model
    }

    /// The dual-path 48 kHz vocoder on a 336-char chunk's features.
    func testVocoderPeak() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["LUXMEM_BENCH"] == "1", "set TEST_RUNNER_LUXMEM_BENCH=1")
        let dir = URL(fileURLWithPath: try XCTUnwrap(env["LUXTTS_WEIGHTS_DIR"]))
        Memory.cacheLimit = 0
        let vocoder = LuxVocoder()
        try vocoder.loadTorchWeights(try loadArrays(url: dir.appendingPathComponent("lux_vocoder.safetensors")))
        MLXRandom.seed(2)
        let features = MLXRandom.normal([1, 2033, 100]) - 3
        eval(features)  // MLX.eval: materialise
        for run in 0 ..< 2 {
            Memory.clearCache()
            let base = Memory.activeMemory
            Memory.peakMemory = 0
            let started = Date()
            let wav = vocoder.decode(features, returnSmooth: false)
            eval(wav)
            print(String(format: "LUXVOC run %d: weights+features %d MB, transient peak %d MB, %.2fs, samples %d",
                         run, base / 1_000_000, (Memory.peakMemory - base) / 1_000_000,
                         Date().timeIntervalSince(started), wav.dim(-1)))
        }
    }

    /// Heap (malloc in use) across vocoder decodes of many lengths: does
    /// each new length leave something behind (JIT kernels, plans)?
    func testVocoderHeapAcrossLengths() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["LUXMEM_BENCH"] == "1", "set LUXMEM_BENCH=1")
        let dir = URL(fileURLWithPath: try XCTUnwrap(env["LUXTTS_WEIGHTS_DIR"]))
        Memory.cacheLimit = 0
        let vocoder = LuxVocoder()
        try vocoder.loadTorchWeights(try loadArrays(url: dir.appendingPathComponent("lux_vocoder.safetensors")))
        func heap() -> Int { var s = malloc_statistics_t(); malloc_zone_statistics(nil, &s); return s.size_in_use / 1_000_000 }
        let lengths = (0 ..< 12).map { 900 + $0 * 113 } + [900, 1013, 1126]
        for n in lengths {
            let f = MLXRandom.normal([1, n, 100]) - 3
            let wav = vocoder.decode(f, returnSmooth: false)
            eval(wav)
            print("LUXHEAP vocoder frames \(n): malloc in use \(heap()) MB, footprint \(FootprintWatch.sample().footprint) MB")
        }
    }

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
        // LUXMEM_HALF_WEIGHTS=1: float16 weights, float32 compute (weights-only).
        if env["LUXMEM_HALF_WEIGHTS"] == "1" {
            model.update(parameters: model.parameters().mapValues { $0.asType(.float16) })
        }
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
            let watch = FootprintWatch()
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
            let w = watch.stop()
            print(String(
                format: "LUXMEM run %d: footprint at start %d MB, max %d MB (graphics %d at max; max graphics %d), MLX active+peak %d MB",
                run, w.start, w.maxFootprint, w.graphicsAtMax, w.maxGraphics, Memory.peakMemory / 1_000_000))
            print(String(
                format: "LUXMEM run %d: frames %d + prompt %d, weights %d MB, transient peak %d MB, cache after %d MB, %.2fs",
                run, out.features.dim(1), promptFrames, base / 1_000_000,
                (Memory.peakMemory - base) / 1_000_000, Memory.cacheMemory / 1_000_000,
                Date().timeIntervalSince(started)))
        }
    }
}

/// phys_footprint and its graphics-tagged part, sampled every 2 ms on a
/// background queue (MB): what the kernel charges, against MLX's counters.
final class FootprintWatch: @unchecked Sendable {
    private let queue = DispatchQueue(label: "luxmem.watch", qos: .userInteractive)
    private let timer: DispatchSourceTimer
    private let lock = NSLock()
    private(set) var start = 0
    private var maxFootprint = 0, graphicsAtMax = 0, maxGraphics = 0

    static func sample() -> (footprint: Int, graphics: Int) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return (Int(info.phys_footprint / 1_000_000), Int(info.ledger_tag_graphics_footprint / 1_000_000))
    }

    init() {
        start = Self.sample().footprint
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let s = Self.sample()
            self.lock.lock()
            if s.footprint > self.maxFootprint { self.maxFootprint = s.footprint; self.graphicsAtMax = s.graphics }
            self.maxGraphics = max(self.maxGraphics, s.graphics)
            self.lock.unlock()
        }
        timer.resume()
    }

    func stop() -> (start: Int, maxFootprint: Int, graphicsAtMax: Int, maxGraphics: Int) {
        timer.cancel()
        queue.sync {}
        lock.lock(); defer { lock.unlock() }
        return (start, maxFootprint, graphicsAtMax, maxGraphics)
    }
}
