import AVFoundation
import Foundation
#if os(macOS)
import COnnxRuntime
#endif

/// Who a clip sounds like: a WeSpeaker speaker-embedding model (e.g. `wespeaker_en_voxceleb_resnet34_LM.onnx`,
/// 26 MB, CPU) through ONNX Runtime, fed Kaldi fbank features — the pipeline sherpa-onnx runs for these models. Promo Studio gates voice takes on the cosine between a take's
/// embedding and the speaker's reference (v2c: speed-1.0 Qwen takes 0.71–0.88, a pitch-shifted take 0.53–0.58,
/// another speaker 0.53). Qwen3-TTS's own speaker encoder can't do this: its raw vectors all score ≈ 0.997.
#if os(macOS)
public final class SpeakerVerifier: @unchecked Sendable {
    let api: OrtApi
    private var env: OpaquePointer?
    private var session: OpaquePointer?
    private var options: OpaquePointer?
    private var inputName = "feats", outputName = "embs"
    private let lock = NSLock()

    public init(modelFile: URL) throws {
        guard FileManager.default.fileExists(atPath: modelFile.path) else { throw SpeakerVerifierError.missing(modelFile.lastPathComponent) }
        guard let base = OrtGetApiBase(), let p = base.pointee.GetApi(UInt32(ORT_API_VERSION)) else { throw SpeakerVerifierError.runtime("OrtGetApiBase returned NULL") }
        api = p.pointee
        try check(api.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "gloam-speaker-id", &env))
        try check(api.CreateSessionOptions(&options))
        try check(api.SetIntraOpNumThreads(options, 2))
        try modelFile.path.withCString { c in try check(api.CreateSession(env, c, options, &session)) }
        var allocator: UnsafeMutablePointer<OrtAllocator>?
        try check(api.GetAllocatorWithDefaultOptions(&allocator))
        var name: UnsafeMutablePointer<CChar>?
        try check(api.SessionGetInputName(session, 0, allocator, &name))
        if let name { inputName = String(cString: name); try check(api.AllocatorFree(allocator, UnsafeMutableRawPointer(name))) }
        name = nil
        try check(api.SessionGetOutputName(session, 0, allocator, &name))
        if let name { outputName = String(cString: name); try check(api.AllocatorFree(allocator, UnsafeMutableRawPointer(name))) }
    }

    deinit {
        if let s = session { api.ReleaseSession(s) }
        if let o = options { api.ReleaseSessionOptions(o) }
        if let e = env { api.ReleaseEnv(e) }
    }

    /// The clip's L2-normalised embedding. Any rate; resampled to 16 kHz.
    public func embedding(samples: [Float], sampleRate: Int) throws -> [Float] {
        let x = sampleRate == KaldiFbank.sampleRate ? samples : Self.resample(samples, from: sampleRate, to: KaldiFbank.sampleRate)
        let (feats, frames) = KaldiFbank.compute(x)
        guard frames > 1 else { throw SpeakerVerifierError.tooShort }
        // No mean normalisation: sherpa-onnx applies one only when the model's metadata asks for it
        // (feature_normalize_type), and the WeSpeaker export doesn't. Checked against sherpa-onnx 1.13.8 on
        // v2's clips: same-file cosine 0.92–0.98, and the cosines to Stefan's reference within ±0.06.
        return try lock.withLock { try run(feats, frames: frames) }
    }

    private func run(_ feats: [Float], frames: Int) throws -> [Float] {
        var memInfo: OpaquePointer?
        try check(api.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memInfo))
        defer { if let m = memInfo { api.ReleaseMemoryInfo(m) } }
        var shape: [Int64] = [1, Int64(frames), Int64(KaldiFbank.melBins)]
        var buf = feats
        var input: OpaquePointer?
        try buf.withUnsafeMutableBytes { raw in
            try check(api.CreateTensorWithDataAsOrtValue(memInfo, raw.baseAddress, raw.count, &shape, shape.count, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &input))
        }
        defer { if let i = input { api.ReleaseValue(i) } }
        var output: OpaquePointer?
        try inputName.withCString { inName in
            try outputName.withCString { outName in
                var ins: [UnsafePointer<CChar>?] = [inName], outs: [UnsafePointer<CChar>?] = [outName]
                var inVals: [OpaquePointer?] = [input]
                try check(api.Run(session, nil, &ins, &inVals, 1, &outs, 1, &output))
            }
        }
        defer { if let o = output { api.ReleaseValue(o) } }
        var info: OpaquePointer?
        try check(api.GetTensorTypeAndShape(output, &info))
        defer { if let i = info { api.ReleaseTensorTypeAndShapeInfo(i) } }
        var count = 0
        try check(api.GetTensorShapeElementCount(info, &count))
        var data: UnsafeMutableRawPointer?
        try check(api.GetTensorMutableData(output, &data))
        guard let data, count > 0 else { throw SpeakerVerifierError.runtime("empty embedding") }
        let v = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? v.map { $0 / norm } : v
    }

    private func check(_ status: OpaquePointer?) throws {
        guard let status else { return }
        let message = api.GetErrorMessage(status).map { String(cString: $0) } ?? "unknown ORT error"
        api.ReleaseStatus(status)
        throw SpeakerVerifierError.runtime(message)
    }

    /// Band-limited resample through AVAudioConverter.
    static func resample(_ s: [Float], from: Int, to: Int) -> [Float] {
        guard let inF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(from), channels: 1, interleaved: false),
              let outF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(to), channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inF, to: outF),
              let inB = AVAudioPCMBuffer(pcmFormat: inF, frameCapacity: AVAudioFrameCount(s.count)) else { return s }
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        inB.frameLength = AVAudioFrameCount(s.count)
        s.withUnsafeBufferPointer { inB.floatChannelData![0].update(from: $0.baseAddress!, count: s.count) }
        let cap = AVAudioFrameCount(Double(s.count) * Double(to) / Double(from)) + 1024
        guard let outB = AVAudioPCMBuffer(pcmFormat: outF, frameCapacity: cap) else { return s }
        var fed = false
        var err: NSError?
        _ = conv.convert(to: outB, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return inB
        }
        return Array(UnsafeBufferPointer(start: outB.floatChannelData![0], count: Int(outB.frameLength)))
    }
}
#endif

public enum SpeakerVerifierError: Error, Equatable, CustomStringConvertible {
    case missing(String), runtime(String), tooShort
    public var description: String {
        switch self {
        case .missing(let f): "The speaker model \(f) isn't there."
        case .runtime(let m): "The speaker model couldn't run: \(m)"
        case .tooShort: "The clip is too short to tell who it is."
        }
    }
}
