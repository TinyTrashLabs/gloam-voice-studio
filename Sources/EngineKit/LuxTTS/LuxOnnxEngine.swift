// LuxOnnxEngine.swift
//
// LuxTTS on ONNX Runtime (CPU), so this repo can run the SAME int8 graphs the
// iOS apps ship — gloam-voice-studio-ios and gloam-dj — beside the native MLX
// implementation in LuxModel/LuxSolver/LuxVocoder.
//
// The point is comparison. MLX here runs fp32 weights converted by
// convert_weights.py; iOS runs `text_encoder_int8.onnx` + `fm_decoder_int8.onnx`
// + `vocos.onnx` on CPU, because iOS forbids GPU submission while backgrounded
// and an MLX synth on a locked screen crashes an audio app. Those are different
// engines at different precisions, and until now there was no way to hear them
// on one machine against one reference.
//
// Ported from gloam-dj's App/LuxOnnx.swift. Two deliberate differences: the
// model directory is passed in rather than read from Bundle.main, and
// tokenization is NOT included — callers supply token ids, so this can share
// LuxTokenizer with the MLX path and leave the engine as the only variable.
//
// Pipeline (luxtts-onnx `LuxTTSOnnx.generate`): text_encoder -> fm_decoder ODE
// loop -> vocos, with the dual-path 48 kHz + 24 kHz Linkwitz-Riley merge in
// vDSP.

import Accelerate
import AVFoundation
import Foundation
import OnnxRuntimeBindings

/// Namespace for the ONNX LuxTTS path's shared types.
public enum LuxOnnx {
    /// Reference-voice encoding. NOT a single vector: the decoder conditions on
    /// the reference's phoneme ids + log-mel frames + RMS.
    public struct Prompt: Sendable, Hashable {
        public let tokens: [Int64]     // phoneme ids of the reference transcript
        public let features: [Float]   // [frames * 100] log-mel * 0.1, row-major (t, mel)
        public let frames: Int
        public let rms: Float          // pre-normalization RMS, for output volume matching

        public init(tokens: [Int64], features: [Float], frames: Int, rms: Float) {
            self.tokens = tokens; self.features = features
            self.frames = frames; self.rms = rms
        }
    }

    public enum SynthError: Error, LocalizedError {
        case modelsMissing(String)
        case engineInitFailed(String)
        case emptyText
        case badPrompt(String)
        case referenceTooLong(Double)
        case emptyAudio
        public var errorDescription: String? {
            switch self {
            case .modelsMissing(let m): return "LuxTTS ONNX models missing: \(m)"
            case .engineInitFailed(let m): return "ONNX Runtime failed: \(m)"
            case .emptyText: return "no tokenizable text"
            case .badPrompt(let m): return "bad LuxTTS voice prompt: \(m)"
            case .referenceTooLong(let s):
                return String(format: "Reference clip is %.0fs — keep it under %.0fs.",
                              s, LuxOnnx.maxReferenceSeconds)
            case .emptyAudio: return "engine returned no samples"
            }
        }
    }

    /// Files the ONNX path needs in its model directory.
    public static let requiredFiles = ["text_encoder_int8.onnx", "fm_decoder_int8.onnx", "vocos.onnx"]

    /// First required file missing from `dir`; nil when complete.
    public static func missingModelFile(in dir: URL) -> String? {
        for f in requiredFiles
        where !FileManager.default.fileExists(atPath: dir.appendingPathComponent(f).path) {
            return f
        }
        return nil
    }

    /// Longest reference clip we will encode. NOT a truncation point: truncating
    /// audio while keeping the whole transcript makes the text encoder think the
    /// reference held more speech than it could hear, and every line comes out
    /// rushed.
    public static let maxReferenceSeconds: Double = 30.0

    /// The rate LuxTTS's mel front end works at.
    public static var sampleRate: Int { LuxMel.sampleRate }

    /// Decode any audio file to mono float at 24 kHz. The ONNX path carries no
    /// MLX dependency, so it cannot borrow MLXAudioCore's loader.
    public static func loadMono24k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(LuxMel.sampleRate),
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target)
        else { throw SynthError.badPrompt("\(url.lastPathComponent): unsupported audio format") }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let ratio = target.sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(file.length) * ratio).rounded(.up)) + 4096
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw SynthError.badPrompt("\(url.lastPathComponent): could not allocate output")
        }
        var readError: Error?
        var convertError: NSError?
        // Bounded by framePosition: reading past the end throws a bridged nil
        // NSError rather than returning zero frames, which is indistinguishable
        // from a real decode failure.
        let status = converter.convert(to: out, error: &convertError) { want, outStatus in
            let remaining = file.length - file.framePosition
            guard remaining > 0 else { outStatus.pointee = .endOfStream; return nil }
            let n = AVAudioFrameCount(min(Int64(max(want, 4096)), remaining))
            guard let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n) else {
                outStatus.pointee = .endOfStream; return nil
            }
            do { try file.read(into: chunk, frameCount: n) } catch {
                readError = error; outStatus.pointee = .endOfStream; return nil
            }
            outStatus.pointee = .haveData
            return chunk
        }
        if let readError { throw readError }
        if let convertError { throw convertError }
        guard status != .error, out.frameLength > 0, let ch = out.floatChannelData else {
            throw SynthError.badPrompt("\(url.lastPathComponent): decoded to no audio")
        }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }

    /// Encode a 24 kHz mono reference plus the token ids of its transcript into a
    /// reusable prompt. Pure mel + arithmetic; no ORT session runs.
    ///
    /// Tokens are supplied rather than derived so this shares LuxTokenizer with
    /// the MLX path — the whole point being to compare engines, not phonemizers.
    public static func encodePrompt(samples24k: [Float], tokens: [Int64]) throws -> Prompt {
        var audio = samples24k
        guard !audio.isEmpty else { throw SynthError.badPrompt("empty reference audio") }
        guard !tokens.isEmpty else { throw SynthError.emptyText }
        audio = LuxMel.trimAndFade(audio)
        audio = LuxMel.removeDC(audio)
        let seconds = Double(audio.count) / Double(LuxMel.sampleRate)
        guard seconds <= maxReferenceSeconds else { throw SynthError.referenceTooLong(seconds) }
        let (normed, rms) = LuxMel.rmsNormUp(audio)
        let (mel, T) = LuxMel.features(normed)
        return Prompt(tokens: tokens, features: mel, frames: T, rms: rms)
    }
}



/// Drives the three LuxTTS graphs through ONNX Runtime's Objective-C API.
///
/// gloam-dj and gloam-voice-studio-ios talk to the ORT **C** API via a vendored
/// xcframework. The SwiftPM distribution exposes only the Objective-C surface —
/// its framework ships no module map, so the C headers are not importable here.
/// Same runtime, same graphs, same CPU execution provider; only the glue
/// differs, and the arithmetic below is byte-for-byte the iOS port's.
public final class LuxEngine {
    private let env: ORTEnv
    private let textEncoder: ORTSession
    private let fmDecoder: ORTSession
    private let vocos: ORTSession
    private let teIn: [String], teOut: [String]
    private let fmIn: [String], fmOut: [String]
    private let voIn: [String], voOut: [String]
    let featDim: Int

    /// Very short text can predict fewer total frames than the prompt occupies;
    /// edge-pad so generation is non-empty (same guard as the Python port).
    static let minGenFrames = 16
    /// Reference level the output is matched back down to when the reference
    /// itself was quieter than this.
    static let targetRMS: Float = 0.1

    public init(modelDir: URL) throws {
        if let missing = LuxOnnx.missingModelFile(in: modelDir) {
            throw LuxOnnx.SynthError.modelsMissing(missing)
        }
        do {
            // `ortEnv` stays local through the loads: a nested helper that read
            // `self.env` would capture self, and self is not fully initialized yet.
            let ortEnv = try ORTEnv(loggingLevel: .warning)
            func session(_ file: String) throws -> ORTSession {
                let opts = try ORTSessionOptions()
                try opts.setGraphOptimizationLevel(.all)
                return try ORTSession(env: ortEnv,
                                      modelPath: modelDir.appendingPathComponent(file).path,
                                      sessionOptions: opts)
            }
            env = ortEnv
            // Build locally, then assign: a stored property cannot be read
            // back inside init until every one of them is initialized.
            let te = try session("text_encoder_int8.onnx")
            let fm = try session("fm_decoder_int8.onnx")
            let vo = try session("vocos.onnx")
            // Input order is load-bearing — the graphs are fed positionally below.
            teIn = try te.inputNames(); teOut = try te.outputNames()
            fmIn = try fm.inputNames(); fmOut = try fm.outputNames()
            voIn = try vo.inputNames(); voOut = try vo.outputNames()
            textEncoder = te; fmDecoder = fm; vocos = vo
        } catch let e as LuxOnnx.SynthError {
            throw e
        } catch {
            throw LuxOnnx.SynthError.engineInitFailed(error.localizedDescription)
        }
        featDim = LuxMel.nMels
    }


    public func synthesize(textIDs: [Int64], prompt: LuxOnnx.Prompt, numSteps: Int, speed: Float,
                    tShift: Float, guidance: Float, dualPath48k: Bool) throws -> (samples: [Float], sampleRate: Int) {
        let steps = max(1, numSteps)
        let mel = LuxMel.nMels

        // ---- text encoder ----
        // prompt_features_len and speed are rank-0 scalars, confirmed against
        // the exported int8 graphs (shape [] int64 / float32).
        let tokensT = try makeInt64Tensor(textIDs, shape: [1, Int64(textIDs.count)])
        let promptT = try makeInt64Tensor(prompt.tokens, shape: [1, Int64(prompt.tokens.count)])
        let featLenT = try makeInt64Tensor([Int64(prompt.frames)], shape: [])
        // NO 1.3 multiplier. The encoder sizes the WHOLE sequence as
        //   F = promptFrames / promptTokens * (promptTokens + textTokens) / speed
        // so dividing by 1.3 shrinks the prompt region too, and the generated
        // audio is whatever survives: F - promptFrames. Measured against this
        // graph, a 120-token line off a 27 s reference yields 1.57 s with the
        // multiplier and 10.20 s without; a 40-token line goes NEGATIVE and
        // falls back to minGenFrames — a fragment. The longer the reference,
        // the more it eats, which is why this got worse once references stopped
        // being truncated. Without it, output holds at ~0.085 s/token across
        // every reference length.
        let speedT = try makeFloatTensor([speed], shape: [])
        let te = try run(textEncoder, inputs: [(teIn[0], tokensT), (teIn[1], promptT),
                                               (teIn[2], featLenT), (teIn[3], speedT)],
                         outputs: [teOut[0]])
        releaseValue(tokensT); releaseValue(promptT); releaseValue(featLenT); releaseValue(speedT)
        let tcShape = tensorShape(te[0])
        var cond = tensorFloats(te[0]); releaseValue(te[0])
        guard tcShape.count == 3, tcShape[2] > 0 else {
            throw LuxOnnx.SynthError.engineInitFailed("text_condition shape \(tcShape)")
        }
        var F = tcShape[1]; let D = tcShape[2]
        // Same guard as the Python port: very short text can predict fewer total
        // frames than the prompt occupies; edge-pad so generation is non-empty.
        let required = prompt.frames + Self.minGenFrames
        if F < required {
            let lastRow = Array(cond[(F - 1) * D ..< F * D])
            for _ in F..<required { cond.append(contentsOf: lastRow) }
            F = required
        }

        // ---- ODE time schedule ----
        var ts = [Float](repeating: 0, count: steps + 1)
        for i in 0...steps {
            let t = Float(i) / Float(steps)
            ts[i] = tShift * t / (1 + (tShift - 1) * t)
        }

        // ---- initial noise + speech condition ----
        var rng = GaussianRNG(seed: 42)
        var x = [Float](repeating: 0, count: F * featDim)
        for i in 0..<x.count { x[i] = Float(rng.nextGaussian()) }
        var speech = [Float](repeating: 0, count: F * mel)
        let copyFrames = min(prompt.frames, F)
        for t in 0..<copyFrames {
            for j in 0..<mel { speech[t * mel + j] = prompt.features[t * mel + j] }
        }

        // ---- flow-matching ODE loop ----
        let condT = try makeFloatTensor(cond, shape: [1, Int64(F), Int64(D)])
        let speechT = try makeFloatTensor(speech, shape: [1, Int64(F), Int64(mel)])
        let guidT = try makeFloatTensor([guidance], shape: [])
        defer { releaseValue(condT); releaseValue(speechT); releaseValue(guidT) }
        for step in 0..<steps {
            let tCur = ts[step], tNext = ts[step + 1]
            let tT = try makeFloatTensor([tCur], shape: [])
            let xT = try makeFloatTensor(x, shape: [1, Int64(F), Int64(featDim)])
            let o = try run(fmDecoder, inputs: [(fmIn[0], tT), (fmIn[1], xT), (fmIn[2], condT),
                                                (fmIn[3], speechT), (fmIn[4], guidT)],
                            outputs: [fmOut[0]])
            releaseValue(tT); releaseValue(xT)
            let v = tensorFloats(o[0]); releaseValue(o[0])
            guard v.count == x.count else {
                throw LuxOnnx.SynthError.engineInitFailed("fm_decoder returned \(v.count) values for \(x.count)")
            }
            // Anchor-based update: blend the x0/x1 predictions toward t_next.
            if step < steps - 1 {
                for i in 0..<x.count {
                    let x1 = x[i] + (1 - tCur) * v[i]
                    let x0 = x[i] - tCur * v[i]
                    x[i] = (1 - tNext) * x0 + tNext * x1
                }
            } else {
                for i in 0..<x.count { x[i] += (1 - tCur) * v[i] }
            }
        }

        // ---- drop the prompt frames, vocode the generated tail ----
        let promptLen = min(prompt.frames, F - 1)
        let Tgen = F - promptLen
        var vin = [Float](repeating: 0, count: featDim * Tgen)
        for t in 0..<Tgen {
            let src = (promptLen + t) * featDim
            for j in 0..<featDim { vin[j * Tgen + t] = x[src + j] / LuxMel.featScale }
        }
        let vinT = try makeFloatTensor(vin, shape: [1, Int64(featDim), Int64(Tgen)])
        let vo = try run(vocos, inputs: [(voIn[0], vinT)], outputs: [voOut[0], voOut[1]])
        releaseValue(vinT)
        let a48 = tensorFloats(vo[0])
        let a24 = tensorFloats(vo[1])
        releaseValue(vo[0]); releaseValue(vo[1])

        var out: [Float]
        let rate: Int
        if dualPath48k {
            out = LuxMel.crossoverMerge(a48, a24); rate = 48000
        } else {
            out = a24; rate = LuxMel.sampleRate
        }
        for i in 0..<out.count { out[i] = min(1, max(-1, out[i])) }
        if prompt.rms < Self.targetRMS {
            let g = prompt.rms / Self.targetRMS
            for i in 0..<out.count { out[i] *= g }
        }
        return (out, rate)
    }

    // MARK: ORT helpers

    /// ORTValue wants NSMutableData it can point at; the shape is [NSNumber].
    private func tensor<T>(_ values: [T], shape: [Int], type: ORTTensorElementDataType) throws -> ORTValue {
        let data = values.withUnsafeBufferPointer {
            NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<T>.stride)
        }
        return try ORTValue(tensorData: data, elementType: type,
                            shape: shape.map { NSNumber(value: $0) })
    }

    private func makeInt64Tensor(_ values: [Int64], shape: [Int64]) throws -> ORTValue {
        try tensor(values, shape: shape.map(Int.init), type: .int64)
    }

    private func makeFloatTensor(_ values: [Float], shape: [Int64]) throws -> ORTValue {
        try tensor(values, shape: shape.map(Int.init), type: .float)
    }

    private func run(_ session: ORTSession, inputs: [(String, ORTValue)],
                     outputs: [String]) throws -> [ORTValue] {
        let out = try session.run(withInputs: Dictionary(uniqueKeysWithValues: inputs),
                                  outputNames: Set(outputs), runOptions: nil)
        return try outputs.map {
            guard let v = out[$0] else {
                throw LuxOnnx.SynthError.engineInitFailed("Run produced no '\($0)' output")
            }
            return v
        }
    }

    private func tensorFloats(_ value: ORTValue) -> [Float] {
        guard let d = try? value.tensorData() else { return [] }
        return (d as Data).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private func tensorShape(_ value: ORTValue) -> [Int] {
        guard let info = try? value.typeInfo(),
              let shape = info.tensorTypeAndShapeInfo?.shape else { return [] }
        return shape.map { $0.intValue }
    }

    /// ORT's Objective-C values are reference-counted; nothing to release by hand.
    private func releaseValue(_ value: ORTValue?) {}
}



// MARK: - Mel features + dual-path merge (ports of the numpy front/back ends)

/// LuxTTS audio math: VocosFbank-matched log-mel extraction (n_fft=1024,
/// hop=256, 100 HTK mels, norm=None, magnitude) and the Linkwitz-Riley
/// crossover that merges the vocoder's 48 kHz + 24 kHz paths.
public enum LuxMel {
    public static let sampleRate = 24000
    static let nFFT = 1024, hop = 256, nMels = 100, freqBins = 513
    static let featScale: Float = 0.1

    /// Port of `rms_norm`: scale UP to the target only, never down. Returns the
    /// (possibly scaled) audio + the original RMS for output volume matching.
    static func rmsNormUp(_ audio: [Float], target: Float = 0.01) -> ([Float], Float) {
        var ss = 0.0
        for v in audio { ss += Double(v) * Double(v) }
        let rms = Float((ss / Double(max(1, audio.count))).squareRoot())
        guard rms > 1e-8, rms < target else { return (audio, rms) }
        let g = target / rms
        return (audio.map { $0 * g }, rms)
    }

    /// Leading and trailing room tone inflates the frame count without adding
    /// any tokens, which skews the frames-per-token ratio the duration
    /// predictor runs on. A short fade avoids the click a hard cut would leave.
    static func trimAndFade(_ samples: [Float], sampleRate: Int = LuxMel.sampleRate,
                            thresholdDB: Float = -42, keepSilenceMs: Float = 35,
                            fadeMs: Float = 12) -> [Float] {
        guard !samples.isEmpty, let peak = samples.map({ abs($0) }).max(), peak > 1e-8 else {
            return samples
        }
        let threshold = peak * pow(10, thresholdDB / 20)
        guard let firstActive = samples.firstIndex(where: { abs($0) > threshold }),
              let lastActive = samples.lastIndex(where: { abs($0) > threshold })
        else { return samples }

        let keep = max(0, Int(Float(sampleRate) * max(keepSilenceMs, 0) / 1000))
        let start = max(0, firstActive - keep)
        let end = min(samples.count, lastActive + keep + 1)
        guard end - start > 8 else { return samples }
        var trimmed = Array(samples[start..<end])

        let fadeSamples = max(0, Int(Float(sampleRate) * max(fadeMs, 0) / 1000))
        if fadeSamples > 1, trimmed.count > fadeSamples * 2 {
            for i in 0..<fadeSamples {
                let ramp = Float(i) / Float(fadeSamples)
                trimmed[i] *= ramp
                trimmed[trimmed.count - 1 - i] *= ramp
            }
        }
        return trimmed
    }

    /// Remove DC bias (matches the macOS engine and LuxTTS-mlx) before mel.
    static func removeDC(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let mean = samples.reduce(Float(0), +) / Float(samples.count)
        return samples.map { $0 - mean }
    }

    /// librosa.filters.mel(sr=24000, n_fft=1024, n_mels=100, htk=True, norm=None):
    /// plain triangular filters on the HTK mel scale, no Slaney area norm.
    static let melBasis: [Float] = {
        func hzToMel(_ f: Double) -> Double { 2595.0 * log10(1.0 + f / 700.0) }
        func melToHz(_ m: Double) -> Double { 700.0 * (pow(10.0, m / 2595.0) - 1.0) }
        let fMax = Double(sampleRate) / 2
        let mMax = hzToMel(fMax)
        let hzPts = (0...(nMels + 1)).map { melToHz(mMax * Double($0) / Double(nMels + 1)) }
        var basis = [Float](repeating: 0, count: nMels * freqBins)
        for m in 0..<nMels {
            let f0 = hzPts[m], f1 = hzPts[m + 1], f2 = hzPts[m + 2]
            for k in 0..<freqBins {
                let f = fMax * Double(k) / Double(freqBins - 1)
                let w = min((f - f0) / max(f1 - f0, 1e-10), (f2 - f) / max(f2 - f1, 1e-10))
                if w > 0 { basis[m * freqBins + k] = Float(w) }
            }
        }
        return basis
    }()

    /// Port of `extract_mel_features`: magnitude STFT (center=True, zero pad —
    /// librosa ≥ 0.10's default pad_mode) → HTK mel → log(clip 1e-7) → × 0.1.
    /// Returns `[T * 100]` row-major (t, mel) ready for the `[1, T, 100]` input.
    static func features(_ audio: [Float]) -> (mel: [Float], T: Int) {
        let pad = nFFT / 2
        var y = [Float](repeating: 0, count: pad)
        y.append(contentsOf: audio)
        y.append(contentsOf: [Float](repeating: 0, count: pad))
        if y.count < nFFT { y.append(contentsOf: [Float](repeating: 0, count: nFFT - y.count)) }
        let T = 1 + (y.count - nFFT) / hop

        // periodic Hann (fftbins=True): w[i] = 0.5 - 0.5 cos(2πi/N)
        var hann = [Float](repeating: 0, count: nFFT)
        for i in 0..<nFFT { hann[i] = 0.5 - 0.5 * cosf(2 * .pi * Float(i) / Float(nFFT)) }

        let log2n = vDSP_Length(10)  // 1024
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        let half = nFFT / 2
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var windowed = [Float](repeating: 0, count: nFFT)

        // magnitude matrix [freqBins, T]
        var mag = [Float](repeating: 0, count: freqBins * T)
        for t in 0..<T {
            let off = t * hop
            for i in 0..<nFFT { windowed[i] = y[off + i] * hann[i] }
            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wb in
                        wb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cb in
                            vDSP_ctoz(cb, 2, &sc, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_FORWARD))
                    // zrip packs DC in realp[0], Nyquist in imagp[0]; scale 2 vs true DFT.
                    let dc = rp[0] * 0.5, nyq = ip[0] * 0.5
                    mag[0 * T + t] = abs(dc)
                    mag[512 * T + t] = abs(nyq)
                    for k in 1..<half {
                        let re = rp[k] * 0.5, im = ip[k] * 0.5
                        mag[k * T + t] = sqrtf(re * re + im * im)
                    }
                }
            }
        }

        // mel = melBasis[100,513] @ mag[513,T] → [100, T]
        var melCT = [Float](repeating: 0, count: nMels * T)
        melBasis.withUnsafeBufferPointer { mb in
            mag.withUnsafeBufferPointer { mg in
                melCT.withUnsafeMutableBufferPointer { out in
                    vDSP_mmul(mb.baseAddress!, 1, mg.baseAddress!, 1, out.baseAddress!, 1,
                              vDSP_Length(nMels), vDSP_Length(T), vDSP_Length(freqBins))
                }
            }
        }
        // log(clip(., 1e-7)) * FEAT_SCALE, transpose [100,T] → [T,100]
        var mel = [Float](repeating: 0, count: T * nMels)
        for m in 0..<nMels {
            for t in 0..<T {
                mel[t * nMels + m] = logf(max(melCT[m * T + t], 1e-7)) * featScale
            }
        }
        return (mel, T)
    }

    /// Port of `crossover_merge`: 4th-order Linkwitz-Riley at 12 kHz — the
    /// 24 kHz path supplies the lows, the 48 kHz path the highs. The 24 kHz
    /// path is 2×-upsampled by linear interpolation (librosa uses a
    /// band-limited resampler; the interp rolloff sits at the crossover corner
    /// where the low path is already attenuated). Filtering runs over a
    /// zero-padded power-of-two FFT rather than the Python's exact-length FFT —
    /// a zero-phase magnitude filter, so only the circular-wrap edges differ.
    static func crossoverMerge(_ a48: [Float], _ a24: [Float],
                               crossoverHz: Float = 12000) -> [Float] {
        guard a48.count > 1, a24.count > 1 else { return a48 }
        var up = [Float](repeating: 0, count: a24.count * 2)
        for i in 0..<a24.count - 1 {
            up[2 * i] = a24[i]
            up[2 * i + 1] = 0.5 * (a24[i] + a24[i + 1])
        }
        up[up.count - 2] = a24[a24.count - 1]
        up[up.count - 1] = a24[a24.count - 1]

        let n = min(a48.count, up.count)
        var log2n: vDSP_Length = 1
        while (1 << log2n) < n { log2n += 1 }
        let nfft = 1 << Int(log2n)
        let half = nfft / 2
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return a48 }
        defer { vDSP_destroy_fftsetup(setup) }

        func spectrum(_ s: ArraySlice<Float>) -> (re: [Float], im: [Float]) {
            var padded = Array(s)
            padded.append(contentsOf: [Float](repeating: 0, count: nfft - padded.count))
            var re = [Float](repeating: 0, count: half)
            var im = [Float](repeating: 0, count: half)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    padded.withUnsafeBufferPointer { pb in
                        pb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cb in
                            vDSP_ctoz(cb, 2, &sc, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            return (re, im)
        }

        var (reM, imM) = spectrum(up[0..<n])          // starts as the 24 kHz (low) spectrum
        let (re48, im48) = spectrum(a48[0..<n])
        let sr: Float = 48000
        func gains(_ f: Float) -> (lo: Float, hi: Float) {
            let b = 1 / (1 + powf(f / crossoverHz, 8))   // Butterworth^2 = Linkwitz-Riley
            return (sqrtf(b), sqrtf(max(0, 1 - b)))
        }
        // zrip packing: DC in re[0] (f = 0 → all low path, so reM[0] stands),
        // Nyquist in im[0].
        let gN = gains(sr / 2)
        imM[0] = imM[0] * gN.lo + im48[0] * gN.hi
        for k in 1..<half {
            let g = gains(Float(k) * sr / Float(nfft))
            reM[k] = reM[k] * g.lo + re48[k] * g.hi
            imM[k] = imM[k] * g.lo + im48[k] * g.hi
        }

        var merged = [Float](repeating: 0, count: nfft)
        reM.withUnsafeMutableBufferPointer { rp in
            imM.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_INVERSE))
                merged.withUnsafeMutableBufferPointer { mb in
                    mb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cb in
                        vDSP_ztoc(&sc, 1, cb, 2, vDSP_Length(half))
                    }
                }
            }
        }
        var scale = 1 / (2 * Float(nfft))                // zrip forward+inverse scales by 2N
        merged.withUnsafeMutableBufferPointer { mb in
            vDSP_vsmul(mb.baseAddress!, 1, &scale, mb.baseAddress!, 1, vDSP_Length(nfft))
        }
        return Array(merged[0..<n])
    }

    /// Linear-interpolation resample — used to bring the engine's 48 kHz
    /// dual-path output to VoiceMixer's native 44.1 kHz (the streamed-chunk
    /// path assumes 44_100 and carries no rate). Linear interp is consistent
    /// with the engine's own 24→48 kHz upsample above; the only content at
    /// risk sits above 22.05 kHz, where the vocoder emits next to nothing.
    static func resampleLinear(_ x: [Float], from src: Int, to dst: Int) -> [Float] {
        guard src != dst, x.count > 1, src > 0, dst > 0 else { return x }
        let n = Int(Double(x.count) * Double(dst) / Double(src))
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        let step = Double(src) / Double(dst)
        for i in 0..<n {
            let pos = Double(i) * step
            let j = min(Int(pos), x.count - 1)
            let f = Float(pos - Double(j))
            let a = x[j]
            let b = x[min(j + 1, x.count - 1)]
            out[i] = a + (b - a) * f
        }
        return out
    }
}

struct GaussianRNG {
    private var state: UInt64
    private var spare: Double?

    init(seed: UInt64) { state = seed }

    private mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    private mutating func nextUniform() -> Double {
        Double(nextUInt64() >> 11) * (1.0 / 9007199254740992.0) // [0,1)
    }

    mutating func nextGaussian() -> Double {
        if let s = spare { spare = nil; return s }
        var u1 = nextUniform()
        while u1 <= .ulpOfOne { u1 = nextUniform() }
        let u2 = nextUniform()
        let r = (-2.0 * Foundation.log(u1)).squareRoot()
        spare = r * sin(2.0 * .pi * u2)
        return r * cos(2.0 * .pi * u2)
    }
}


