// LuxTTS top-level model: ZipVoice-Distill (the 4-step distilled ZipVoice
// flow-matching TTS), ported from the torch reference
// zipvoice/models/zipvoice.py (ZipVoice) and zipvoice/models/zipvoice_distill.py
// (ZipVoiceDistill), plus the helpers pad_labels / make_pad_mask /
// prepare_avg_tokens_durations / get_tokens_index from zipvoice/utils/common.py.
// The `duration_pad_frames` knob follows LuxTTS's own inference API
// (LuxTTS-mlx zipvoice/mlx/model.py), which extends the reference.

import Foundation
import MLX
import MLXNN

/// Model hyperparameters; literal values from YatharthS/LuxTTS config.json.
/// Decodes directly from that file's snake_case keys, falling back to these
/// defaults for absent fields (vocab_size, pad_id).
public struct LuxTTSConfig: Codable, Sendable {
    public var fmDecoderDownsamplingFactor: [Int] = [1, 2, 4, 2, 1]
    public var fmDecoderNumLayers: [Int] = [2, 2, 4, 4, 4]
    public var fmDecoderCnnModuleKernel: [Int] = [31, 15, 7, 15, 31]
    public var fmDecoderFeedforwardDim: Int = 1536
    public var fmDecoderNumHeads: Int = 4
    public var fmDecoderDim: Int = 512
    public var textEncoderNumLayers: Int = 4
    public var textEncoderFeedforwardDim: Int = 512
    public var textEncoderCnnModuleKernel: Int = 9
    public var textEncoderNumHeads: Int = 4
    public var textEncoderDim: Int = 192
    public var queryHeadDim: Int = 32
    public var valueHeadDim: Int = 12
    public var posHeadDim: Int = 4
    public var posDim: Int = 48
    public var timeEmbedDim: Int = 192
    public var textEmbedDim: Int = 192
    public var featDim: Int = 100
    public var vocabSize: Int = 360
    public var padId: Int = 0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case fmDecoderDownsamplingFactor = "fm_decoder_downsampling_factor"
        case fmDecoderNumLayers = "fm_decoder_num_layers"
        case fmDecoderCnnModuleKernel = "fm_decoder_cnn_module_kernel"
        case fmDecoderFeedforwardDim = "fm_decoder_feedforward_dim"
        case fmDecoderNumHeads = "fm_decoder_num_heads"
        case fmDecoderDim = "fm_decoder_dim"
        case textEncoderNumLayers = "text_encoder_num_layers"
        case textEncoderFeedforwardDim = "text_encoder_feedforward_dim"
        case textEncoderCnnModuleKernel = "text_encoder_cnn_module_kernel"
        case textEncoderNumHeads = "text_encoder_num_heads"
        case textEncoderDim = "text_encoder_dim"
        case queryHeadDim = "query_head_dim"
        case valueHeadDim = "value_head_dim"
        case posHeadDim = "pos_head_dim"
        case posDim = "pos_dim"
        case timeEmbedDim = "time_embed_dim"
        case textEmbedDim = "text_embed_dim"
        case featDim = "feat_dim"
        case vocabSize = "vocab_size"
        case padId = "pad_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LuxTTSConfig()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        fmDecoderDownsamplingFactor = try value(
            .fmDecoderDownsamplingFactor, defaults.fmDecoderDownsamplingFactor)
        fmDecoderNumLayers = try value(.fmDecoderNumLayers, defaults.fmDecoderNumLayers)
        fmDecoderCnnModuleKernel = try value(
            .fmDecoderCnnModuleKernel, defaults.fmDecoderCnnModuleKernel)
        fmDecoderFeedforwardDim = try value(
            .fmDecoderFeedforwardDim, defaults.fmDecoderFeedforwardDim)
        fmDecoderNumHeads = try value(.fmDecoderNumHeads, defaults.fmDecoderNumHeads)
        fmDecoderDim = try value(.fmDecoderDim, defaults.fmDecoderDim)
        textEncoderNumLayers = try value(.textEncoderNumLayers, defaults.textEncoderNumLayers)
        textEncoderFeedforwardDim = try value(
            .textEncoderFeedforwardDim, defaults.textEncoderFeedforwardDim)
        textEncoderCnnModuleKernel = try value(
            .textEncoderCnnModuleKernel, defaults.textEncoderCnnModuleKernel)
        textEncoderNumHeads = try value(.textEncoderNumHeads, defaults.textEncoderNumHeads)
        textEncoderDim = try value(.textEncoderDim, defaults.textEncoderDim)
        queryHeadDim = try value(.queryHeadDim, defaults.queryHeadDim)
        valueHeadDim = try value(.valueHeadDim, defaults.valueHeadDim)
        posHeadDim = try value(.posHeadDim, defaults.posHeadDim)
        posDim = try value(.posDim, defaults.posDim)
        timeEmbedDim = try value(.timeEmbedDim, defaults.timeEmbedDim)
        textEmbedDim = try value(.textEmbedDim, defaults.textEmbedDim)
        featDim = try value(.featDim, defaults.featDim)
        vocabSize = try value(.vocabSize, defaults.vocabSize)
        padId = try value(.padId, defaults.padId)
    }
}

/// zipvoice.py `sample(duration=...)`: "predict" derives output length from
/// the prompt's frames-per-token ratio; "real" uses caller-provided lengths.
public enum LuxDurationMode: Sendable {
    case predict
    case real
}

/// Result of `ZipVoiceDistill.sample`, matching the torch return tuple
/// (x1_wo_prompt, x1_wo_prompt_lens, x1_prompt, prompt_features_lens).
public struct LuxSampleOutput {
    /// Generated features with the prompt removed, zero-padded: (batch, maxLen, featDim).
    public let features: MLXArray
    public let featureLengths: [Int]
    /// The re-generated prompt region, zero-padded: (batch, maxPromptLen, featDim).
    public let promptFeatures: MLXArray
    public let promptFeatureLengths: [Int]
}

/// utils/common.py `make_pad_mask`: (B, maxLen) bool, true = padding.
func luxMakePadMask(lengths: [Int], maxLen: Int) -> MLXArray {
    let positions = MLXArray(Array(0 ..< Int32(max(maxLen, 0))))
    let lens = MLXArray(lengths.map(Int32.init))
    return positions.expandedDimensions(axis: 0) .>= lens.expandedDimensions(axis: 1)
}

/// zipvoice_distill.py `ZipVoiceDistill` (which is zipvoice.py `ZipVoice` with
/// the fm_decoder rebuilt with a guidance-scale embedding, and a
/// DistillEulerSolver). Only the inference path is ported.
public final class ZipVoiceDistill: Module, LuxFlowMatchingModel {
    public let config: LuxTTSConfig

    @ModuleInfo(key: "fm_decoder") var fmDecoder: TTSZipformer
    @ModuleInfo(key: "text_encoder") var textEncoder: TTSZipformer
    @ModuleInfo(key: "embed") var embed: Embedding

    public private(set) var solver: DistillEulerSolver!

    public init(config: LuxTTSConfig = LuxTTSConfig()) {
        self.config = config

        self._fmDecoder.wrappedValue = TTSZipformer(
            inDim: config.featDim * 3,
            outDim: config.featDim,
            downsamplingFactor: config.fmDecoderDownsamplingFactor,
            numEncoderLayers: config.fmDecoderNumLayers,
            cnnModuleKernel: config.fmDecoderCnnModuleKernel,
            encoderDim: config.fmDecoderDim,
            queryHeadDim: config.queryHeadDim,
            posHeadDim: config.posHeadDim,
            valueHeadDim: config.valueHeadDim,
            numHeads: config.fmDecoderNumHeads,
            feedforwardDim: config.fmDecoderFeedforwardDim,
            posDim: config.posDim,
            useTimeEmbed: true,
            timeEmbedDim: config.timeEmbedDim,
            useGuidanceScaleEmbed: true,
            guidanceScaleEmbedDim: config.timeEmbedDim
        )

        self._textEncoder.wrappedValue = TTSZipformer(
            inDim: config.textEmbedDim,
            outDim: config.featDim,
            downsamplingFactor: [1],
            numEncoderLayers: [config.textEncoderNumLayers],
            cnnModuleKernel: [config.textEncoderCnnModuleKernel],
            encoderDim: config.textEncoderDim,
            queryHeadDim: config.queryHeadDim,
            posHeadDim: config.posHeadDim,
            valueHeadDim: config.valueHeadDim,
            numHeads: config.textEncoderNumHeads,
            feedforwardDim: config.textEncoderFeedforwardDim,
            posDim: config.posDim,
            useTimeEmbed: false
        )

        self._embed.wrappedValue = Embedding(
            embeddingCount: config.vocabSize, dimensions: config.textEmbedDim)

        super.init()
        self.solver = DistillEulerSolver(model: self)
    }

    // MARK: - Flow-matching decoder

    /// zipvoice.py `forward_fm_decoder`: concatenates [xt, text, speech]
    /// conditions on the feature axis and predicts velocity.
    public func forwardFMDecoder(
        t: MLXArray,
        xt: MLXArray,
        textCondition: MLXArray,
        speechCondition: MLXArray,
        paddingMask: MLXArray?,
        guidanceScale: MLXArray?
    ) -> MLXArray {
        let xt = concatenated([xt, textCondition, speechCondition], axis: 2)

        var t = t
        while t.ndim > 1 && t.dim(-1) == 1 {
            t = t.squeezed(axis: -1)
        }
        if t.ndim == 0 {
            t = broadcast(t, to: [xt.dim(0)])
        }

        var guidance = guidanceScale
        if var g = guidance {
            while g.ndim > 1 && g.dim(-1) == 1 {
                g = g.squeezed(axis: -1)
            }
            if g.ndim == 0 {
                g = broadcast(g, to: [xt.dim(0)])
            }
            guidance = g
        }

        return fmDecoder(xt, t: t, paddingMask: paddingMask, guidanceScale: guidance)
    }

    // MARK: - Text conditioning

    /// zipvoice.py `forward_text_embed`. Note pad_labels appends one extra
    /// pad token to every sequence before length-padding; frames past the last
    /// token's duration index that trailing pad position.
    func forwardTextEmbed(tokens: [[Int]]) -> (embed: MLXArray, tokensLens: [Int]) {
        let appended = tokens.map { $0 + [config.padId] }
        let maxLen = appended.map(\.count).max() ?? 1
        var flat: [Int32] = []
        flat.reserveCapacity(tokens.count * maxLen)
        for row in appended {
            flat.append(contentsOf: row.map(Int32.init))
            flat.append(contentsOf: repeatElement(Int32(config.padId), count: maxLen - row.count))
        }
        let tokensPadded = MLXArray(flat, [tokens.count, maxLen])

        var embedded = embed(tokensPadded)
        let tokensLens = tokens.map(\.count)
        let tokensPaddingMask = luxMakePadMask(lengths: tokensLens, maxLen: maxLen)
        embedded = textEncoder(embedded, t: nil, paddingMask: tokensPaddingMask)
        return (embedded, tokensLens)
    }

    /// zipvoice.py `forward_text_condition` + utils/common.py
    /// `prepare_avg_tokens_durations` / `get_tokens_index`: spreads each
    /// token's encoding uniformly over its average duration in frames.
    func forwardTextCondition(
        embed: MLXArray,
        tokensLens: [Int],
        featuresLens: [Int]
    ) -> (textCondition: MLXArray, paddingMask: MLXArray) {
        let batchSize = featuresLens.count
        let numFrames = featuresLens.max() ?? 0
        let paddingMask = luxMakePadMask(lengths: featuresLens, maxLen: numFrames)

        var indexRows: [Int32] = []
        indexRows.reserveCapacity(batchSize * numFrames)
        for b in 0 ..< batchSize {
            let avgDuration = featuresLens[b] / tokensLens[b]
            var durations = Array(repeating: avgDuration, count: tokensLens[b])
            durations.append(numFrames - durations.reduce(0, +))
            var filled = 0
            for (i, d) in durations.enumerated() where d > 0 {
                indexRows.append(contentsOf: repeatElement(Int32(i), count: d))
                filled += d
            }
            precondition(filled == numFrames)
        }
        let tokensIndex = MLXArray(indexRows, [batchSize, numFrames])

        // torch.gather along dim 1 == takeAlong with indices broadcast to
        // (B, numFrames, embedDim).
        let indices = broadcast(
            tokensIndex.expandedDimensions(axis: -1),
            to: [batchSize, numFrames, embed.dim(-1)]
        )
        let textCondition = takeAlong(embed, indices, axis: 1)
        return (textCondition, paddingMask)
    }

    /// zipvoice.py `forward_text_inference_gt_duration`.
    func forwardTextInferenceGtDuration(
        tokens: [[Int]],
        featuresLens: [Int],
        promptTokens: [[Int]],
        promptFeaturesLens: [Int]
    ) -> (textCondition: MLXArray, paddingMask: MLXArray, totalLens: [Int]) {
        let catTokens = zip(promptTokens, tokens).map { $0 + $1 }
        let totalLens = zip(promptFeaturesLens, featuresLens).map(+)
        let (embedded, tokensLens) = forwardTextEmbed(tokens: catTokens)
        let (textCondition, paddingMask) = forwardTextCondition(
            embed: embedded, tokensLens: tokensLens, featuresLens: totalLens)
        return (textCondition, paddingMask, totalLens)
    }

    /// zipvoice.py `forward_text_inference_ratio_duration`, extended with the
    /// LuxTTS `duration_pad_frames` knob (added to the predicted length) and
    /// the token-length floor of 1 from the LuxTTS MLX port.
    func forwardTextInferenceRatioDuration(
        tokens: [[Int]],
        promptTokens: [[Int]],
        promptFeaturesLens: [Int],
        speed: Float,
        durationPadFrames: Int
    ) -> (textCondition: MLXArray, paddingMask: MLXArray, totalLens: [Int]) {
        precondition(speed > 0)
        let catTokens = zip(promptTokens, tokens).map { $0 + $1 }
        let promptTokensLens = promptTokens.map { max($0.count, 1) }
        let tokensLens = tokens.map { max($0.count, 1) }

        let (catEmbed, catTokensLens) = forwardTextEmbed(tokens: catTokens)

        let padFrames = max(durationPadFrames, 0)
        var totalLens: [Int] = []
        totalLens.reserveCapacity(tokens.count)
        for i in 0 ..< tokens.count {
            // torch does this in float32 tensor math; Double here. Only differs
            // if the ratio lands exactly on an integer boundary under float32.
            let predicted = Int(
                (Double(promptFeaturesLens[i]) / Double(promptTokensLens[i])
                    * Double(tokensLens[i]) / Double(speed))
                    .rounded(.up))
            totalLens.append(promptFeaturesLens[i] + predicted + padFrames)
        }

        let (textCondition, paddingMask) = forwardTextCondition(
            embed: catEmbed, tokensLens: catTokensLens, featuresLens: totalLens)
        return (textCondition, paddingMask, totalLens)
    }

    // MARK: - Sampling

    /// zipvoice.py `sample`: text conditioning -> duration -> flow-matching
    /// ODE solve from noise -> split prompt / generated features.
    ///
    /// - Parameters:
    ///   - tokens: token ids of the text to synthesize, one row per batch item.
    ///   - promptTokens: token ids of the prompt transcription.
    ///   - promptFeatures: prompt acoustic features (batch, promptLen, featDim).
    ///   - promptFeaturesLens: valid length of each prompt row.
    ///   - featuresLens: target feature lengths; required for `duration: .real`.
    ///   - duration: length strategy, `.predict` (default) or `.real`.
    ///   - numSteps: ODE solver steps (LuxTTS default 4).
    ///   - guidanceScale: classifier-free guidance scale (LuxTTS default 3.0).
    ///   - tShift: timestep-schedule shift (LuxTTS default 0.5).
    ///   - speed: speaking-rate divisor for the predicted duration (default 1.0).
    ///   - durationPadFrames: extra frames appended to the predicted duration.
    ///   - noise: fixed initial noise (batch, numFrames, featDim) for
    ///     reproducibility / parity testing; random normal when nil.
    public func sample(
        tokens: [[Int]],
        promptTokens: [[Int]],
        promptFeatures: MLXArray,
        promptFeaturesLens: [Int],
        featuresLens: [Int]? = nil,
        duration: LuxDurationMode = .predict,
        numSteps: Int = 4,
        guidanceScale: Float = 3.0,
        tShift: Float = 0.5,
        speed: Float = 1.0,
        durationPadFrames: Int = 0,
        noise: MLXArray? = nil
    ) -> LuxSampleOutput {
        let textCondition: MLXArray
        let paddingMask: MLXArray
        let totalLens: [Int]

        switch duration {
        case .predict:
            (textCondition, paddingMask, totalLens) = forwardTextInferenceRatioDuration(
                tokens: tokens,
                promptTokens: promptTokens,
                promptFeaturesLens: promptFeaturesLens,
                speed: speed,
                durationPadFrames: durationPadFrames
            )
        case .real:
            guard let featuresLens else {
                fatalError("featuresLens is required for duration: .real")
            }
            (textCondition, paddingMask, totalLens) = forwardTextInferenceGtDuration(
                tokens: tokens,
                featuresLens: featuresLens,
                promptTokens: promptTokens,
                promptFeaturesLens: promptFeaturesLens
            )
        }

        let batchSize = textCondition.dim(0)
        let numFrames = textCondition.dim(1)
        let featDim = promptFeatures.dim(-1)

        precondition(numFrames >= promptFeatures.dim(1))
        var speechCondition = padded(
            promptFeatures,
            widths: [[0, 0], [0, numFrames - promptFeatures.dim(1)], [0, 0]]
        )
        let speechConditionMask = luxMakePadMask(lengths: promptFeaturesLens, maxLen: numFrames)
        speechCondition = which(
            speechConditionMask.expandedDimensions(axis: -1),
            zeros(like: speechCondition),
            speechCondition
        )

        let x0 = noise ?? MLXRandom.normal([batchSize, numFrames, featDim])

        if ProcessInfo.processInfo.environment["LUXTTS_DUMP_DEBUG"] != nil {
            func dump(_ arr: MLXArray, _ path: String) {
                // MLX.eval: lazy-graph materialization, not code evaluation.
                eval(arr)
                let flat = arr.reshaped([-1]).asType(.float32).asArray(Float.self)
                var data = Foundation.Data()
                for v in flat { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }
                try? data.write(to: URL(fileURLWithPath: path))
                FileHandle.standardError.write(Foundation.Data(
                    "DEBUG dumped \(path) shape=\(arr.shape)\n".utf8))
            }
            dump(textCondition, "/tmp/lux_dbg_text_condition.f32")
            dump(speechCondition, "/tmp/lux_dbg_speech_condition.f32")
            dump(x0, "/tmp/lux_dbg_x0.f32")
            FileHandle.standardError.write(Foundation.Data(
                "DEBUG tokens=\(tokens)\nDEBUG promptTokens=\(promptTokens)\nDEBUG totalLens=\(totalLens) promptFeaturesLens=\(promptFeaturesLens)\n".utf8))
        }

        let x1 = solver.sample(
            x: x0,
            textCondition: textCondition,
            speechCondition: speechCondition,
            paddingMask: paddingMask,
            numSteps: numSteps,
            guidanceScale: guidanceScale,
            tStart: 0.0,
            tEnd: 1.0,
            tShift: tShift
        )

        if ProcessInfo.processInfo.environment["LUXTTS_DUMP_DEBUG"] != nil {
            func dump(_ arr: MLXArray, _ path: String) {
                let flat = arr.reshaped([-1]).asArray(Float.self)
                var data = Foundation.Data()
                for v in flat { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }
                try? data.write(to: URL(fileURLWithPath: path))
                FileHandle.standardError.write(Foundation.Data(
                    "DEBUG dumped \(path) shape=\(arr.shape) count=\(flat.count)\n".utf8))
            }
            let promptLen0 = promptFeaturesLens[0]
            dump(x1[0, 0 ..< promptLen0], "/tmp/lux_x1_prompt_region.f32")
            dump(promptFeatures[0, 0 ..< promptLen0], "/tmp/lux_input_prompt_features.f32")
        }

        let withoutPromptLens = zip(totalLens, promptFeaturesLens).map(-)
        let maxPromptLen = promptFeaturesLens.max() ?? 0
        let maxWithoutPromptLen = withoutPromptLens.max() ?? 0

        var promptRows: [MLXArray] = []
        var generatedRows: [MLXArray] = []
        for i in 0 ..< batchSize {
            let promptLen = promptFeaturesLens[i]
            let generatedLen = withoutPromptLens[i]

            var promptRow = x1[i, 0 ..< promptLen]
            if promptLen < maxPromptLen {
                promptRow = padded(promptRow, widths: [[0, maxPromptLen - promptLen], [0, 0]])
            }
            promptRows.append(promptRow)

            var generatedRow = x1[i, promptLen ..< (promptLen + generatedLen)]
            if generatedLen < maxWithoutPromptLen {
                generatedRow = padded(
                    generatedRow, widths: [[0, maxWithoutPromptLen - generatedLen], [0, 0]])
            }
            generatedRows.append(generatedRow)
        }

        return LuxSampleOutput(
            features: stacked(generatedRows, axis: 0),
            featureLengths: withoutPromptLens,
            promptFeatures: stacked(promptRows, axis: 0),
            promptFeatureLengths: promptFeaturesLens
        )
    }
}
