import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers

/// Production LanguageModelProviding backed by mlx-swift-lm.
/// Must only be used from the GloamEngine actor.
public final class MLXLanguageModelProvider: LanguageModelProviding, @unchecked Sendable {
    /// Resolves a backend to a local model directory (whose config.json exists).
    /// The app injects a resolver pointing at its managed Caches/Models directory
    /// so weights always arrive through the in-app download manager — loading
    /// from a local directory means no network fetch happens here.
    private let modelDirectoryResolver: @Sendable (LLMBackendID) -> URL

    public init(modelDirectoryResolver: @escaping @Sendable (LLMBackendID) -> URL) {
        self.modelDirectoryResolver = modelDirectoryResolver
    }

    public func loadModel(backend: LLMBackendID) async throws -> any LanguageModel {
        let dir = modelDirectoryResolver(backend)

        // Mixture-of-Experts Gemma-4 (e.g. gemma-4-26b-a4b) ships as a
        // `Gemma4ForConditionalGeneration`. Its MoE text stack — `num_experts`,
        // `router`, the SwitchGLU experts, the extra pre/post-feedforward norms —
        // is implemented ONLY in the VLM factory's Gemma4. The default LLM loader
        // matches model_type "gemma4" to the DENSE Gemma4 first and then dies on the
        // MoE weights (`unhandledKeys([experts, router, …])`). So route a MoE gemma
        // through the VLM factory, which builds the correct architecture; text
        // generation then runs identically (no images) via ChatSession. Dense
        // gemmas (e2b/e4b) and non-gemma models keep the default LLM path.
        let container: ModelContainer
        if backend.family == .gemma, Self.isMoEConfig(dir) || Self.hasVisionTower(dir) {
            // VLM factory also whenever the checkpoint ships a vision tower:
            // the generic loader builds a TEXT-ONLY gemma whose processor
            // silently drops attached images ("I do not see an image").
            container = try await VLMModelFactory.shared.loadContainer(
                from: dir, using: #huggingFaceTokenizerLoader())
        } else {
            // `#huggingFaceLoadModelContainer` expands to `loadModelContainer(from:
            // #hubDownloader(), using: #huggingFaceTokenizerLoader(), configuration:)`.
            // For a `.directory` configuration the downloader is never invoked (resolve
            // short-circuits to the local path); only the tokenizer loader runs against
            // the on-disk folder.
            container = try await #huggingFaceLoadModelContainer(
                configuration: ModelConfiguration(directory: dir))
        }
        return MLXLanguageModel(container: container, family: backend.family)
    }

    /// Whether the model at `dir` declares a Mixture-of-Experts block in its
    /// config.json (top-level or under `text_config`). MoE gemmas must load via
    /// the VLM factory; dense ones use the LLM factory. Reads the small config
    /// file only — no weights touched.
    /// Whether the checkpoint is a unified multimodal gemma (vision tower in
    /// config.json) — those must load via the VLM factory to see images.
    private static func hasVisionTower(_ dir: URL) -> Bool {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("config.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return json["vision_config"] != nil
    }

    private static func isMoEConfig(_ dir: URL) -> Bool {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("config.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        if json["enable_moe_block"] as? Bool == true { return true }
        if let text = json["text_config"] as? [String: Any],
           text["enable_moe_block"] as? Bool == true { return true }
        return false
    }

    public func didEvictModel() {
        MLX.Memory.clearCache()
    }
}

/// Wraps a loaded ModelContainer; runs a single-shot chat completion with
/// thinking suppression applied per family.
final class MLXLanguageModel: LanguageModel, @unchecked Sendable {
    private let container: ModelContainer
    private let family: LLMFamily

    init(container: ModelContainer, family: LLMFamily) {
        self.container = container
        self.family = family
    }

    /// Maps the request's sampler surface onto mlx-swift-lm's GenerateParameters.
    /// nil request fields keep the library defaults (topK 0 = off, minP 0 = off).
    static func generateParameters(for request: ChatRequest) -> GenerateParameters {
        var params = GenerateParameters(
            maxTokens: request.maxTokens,
            temperature: request.temperature,
            topP: request.topP ?? 1.0)
        if let topK = request.topK { params.topK = topK }
        if let minP = request.minP { params.minP = minP }
        params.repetitionPenalty = request.repetitionPenalty
        if let size = request.repetitionContextSize { params.repetitionContextSize = size }
        params.presencePenalty = request.presencePenalty
        params.frequencyPenalty = request.frequencyPenalty
        return params
    }

    /// The request decomposed into prompt-side pieces. Shared by the paced
    /// TokenIterator path and the ChatSession (tool-calling) path so the two
    /// can never drift on thinking suppression or system-turn handling.
    private struct PreparedChat {
        var instructions: String?
        var historyTurns: [ChatTurn]
        var lastUser: String
        var additionalContext: [String: any Sendable]
    }

    private static func chatMessage(from turn: ChatTurn) -> Chat.Message {
        switch turn.role {
        case .assistant: .assistant(turn.content)
        case .user: .user(turn.content)
        case .tool: .tool(turn.content)
        case .system: .system(turn.content)
        }
    }

    /// Mutating prompt steps (system-turn merge, thinking suppression,
    /// final-turn reinforcement), unchanged from the original complete()
    /// implementation.
    private func preparedChat(_ request: ChatRequest) throws -> PreparedChat {
        // 1. Thinking-off via tokenizer chat-template flag.
        var additionalContext: [String: any Sendable] = [:]
        if request.disableThinking { additionalContext["enable_thinking"] = false }

        var turns = request.messages
        // Concatenate ALL system turns (not just the first) so none are silently lost.
        let systemText: String? = {
            let systems = turns.filter { $0.role == .system }.map(\.content)
            return systems.isEmpty ? nil : systems.joined(separator: "\n\n")
        }()
        turns.removeAll { $0.role == .system }

        // 2. Belt-and-suspenders "no reasoning" reinforcement, applied for ALL families
        //    when disableThinking is true. This catches models that ignore the chat-template
        //    flag (step 1) or don't honour /no_think / prefix tricks.
        //    Qwen additionally gets " /no_think" appended to the final user turn (below).
        //    Gemma additionally gets an "Answer directly…" prefix on the final user turn.
        var instructions = systemText
        if request.disableThinking {
            let noThink = "Answer directly. Do not produce any reasoning, planning, or <think> content."
            instructions = [instructions, noThink].compactMap { $0 }.joined(separator: "\n\n")
        }

        guard let lastUserIdx = turns.lastIndex(where: { $0.role == .user }) else {
            throw EngineError.languageProviderUnavailable
        }
        var lastUser = turns.remove(at: lastUserIdx).content
        // 3. Final-user-turn reinforcement: /no_think for Qwen, plain instruction for Gemma.
        if request.disableThinking, family == .qwen {
            lastUser += " /no_think"
        } else if request.disableThinking, family == .gemma {
            lastUser = "Answer directly with no reasoning.\n\n" + lastUser
        }

        return PreparedChat(instructions: instructions, historyTurns: turns,
                            lastUser: lastUser, additionalContext: additionalContext)
    }

    func complete(_ request: ChatRequest) async throws -> ChatResult {
        for try await event in stream(request) {
            if case .finished(let result) = event { return result }
        }
        // stream() always yields .finished before finishing; reaching here
        // means the task was cancelled mid-generation.
        throw CancellationError()
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.pacedStream(request) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func pacedStream(_ request: ChatRequest,
                     onEvent: @Sendable (ChatEvent) async -> Void) async throws {
        // Tool-calling needs ChatSession's tool-call parser; those requests come
        // from the server route, never the chat UI, so pacing doesn't matter there.
        if let tools = request.tools, !tools.isEmpty {
            try await chatSessionStream(request, onEvent: onEvent)
            return
        }

        let start = Date()
        let prepared = try preparedChat(request)
        // Capture only Sendable pieces (UserInput/Chat.Message are not Sendable —
        // they can carry MLXArray images); rebuild the chat inside the closure.
        let instructions = prepared.instructions
        let historyTurns = prepared.historyTurns
        let lastUser = prepared.lastUser
        let additionalContext = prepared.additionalContext
        let imageURLs = request.imageURLs ?? []
        let params = Self.generateParameters(for: request)

        try await container.perform { context in
            var messages: [Chat.Message] = []
            if let instructions { messages.append(.system(instructions)) }
            messages.append(contentsOf: historyTurns.map(Self.chatMessage(from:)))
            messages.append(.user(lastUser, images: imageURLs.map { .url($0) }))
            let userInput = UserInput(
                chat: messages,
                additionalContext: additionalContext.isEmpty ? nil : additionalContext)
            let input = try await context.processor.prepare(input: userInput)
            let promptTokens = input.text.tokens.size
            var iterator = try TokenIterator(
                input: input, model: context.model, cache: nil, parameters: params)
            var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)

            // Same stop set generateLoopTask builds (its builder is private).
            var stopIds = context.configuration.eosTokenIds
            if let eos = context.tokenizer.eosTokenId { stopIds.insert(eos) }
            for token in context.configuration.extraEOSTokens {
                if let id = context.tokenizer.convertTokenToId(token) { stopIds.insert(id) }
            }

            var rawText = ""
            var completionTokens = 0
            var generationStart: Date?
            // Pull-based decode. Note next() pipelines: it launches asyncEval
            // of the FOLLOWING token before returning this one, so the gap is
            // only truly GPU-idle after awaitPendingComputation() — the engine
            // calls it before interleaving synthesis. The synchronize below
            // also settles the dangling eval a stop-token break leaves behind
            // (the library's own loop does the same; unsettled tasks hit
            // scheduler-teardown assertions).
            defer { MLX.Stream().synchronize() }
            while let token = iterator.next() {
                try Task.checkCancellation()
                if generationStart == nil { generationStart = Date() }
                if token == context.tokenizer.unknownTokenId || stopIds.contains(token) { break }
                completionTokens += 1
                detokenizer.append(token: token)
                if let chunk = detokenizer.next() {
                    rawText += chunk
                    await onEvent(.delta(chunk))
                }
            }

            let generationSeconds = generationStart.map { Date().timeIntervalSince($0) } ?? 0
            // Final safety net — strip any leaked <think>…</think> block.
            let cleaned = request.disableThinking ? stripThinking(rawText) : rawText
            await onEvent(.finished(ChatResult(
                text: cleaned,
                toolCalls: [],
                usage: ChatUsage(promptTokens: promptTokens,
                                 completionTokens: completionTokens),
                wallSeconds: Date().timeIntervalSince(start),
                tokensPerSecond: generationSeconds > 0
                    ? Double(completionTokens) / generationSeconds : nil)))
        }
    }

    func awaitPendingComputation() async {
        // Settle the pipelined next-token eval so interleaved TTS never
        // overlaps LLM GPU work.
        MLX.Stream().synchronize()
    }

    /// ChatSession-backed streaming, kept only for tool-calling requests (the
    /// session's handler parses tool calls out of the token stream).
    private func chatSessionStream(
        _ request: ChatRequest,
        onEvent: @Sendable (ChatEvent) async -> Void
    ) async throws {
        let start = Date()
        let prepared = try preparedChat(request)
        let toolSpecs: [ToolSpec]? = try request.tools.map { try $0.map { try toolSpec(from: $0) } }
        let session = ChatSession(
            container,
            instructions: prepared.instructions,
            history: prepared.historyTurns.map(Self.chatMessage(from:)),
            generateParameters: Self.generateParameters(for: request),
            additionalContext: prepared.additionalContext.isEmpty ? nil : prepared.additionalContext,
            tools: toolSpecs)

        var rawText = ""
        var toolCalls: [LLMToolCall] = []
        var promptTokens = 0
        var completionTokens = 0
        var tokensPerSecond: Double?
        for try await generation in session.streamDetails(
            to: prepared.lastUser,
            images: (request.imageURLs ?? []).map { .url($0) }, videos: []) {
            try Task.checkCancellation()
            switch generation {
            case .chunk(let t):
                rawText += t
                await onEvent(.delta(t))
            case .toolCall(let call):
                // NOTE: mlx-swift-lm v3.31.3 (issue #259) does NOT parse
                // Gemma-4 tool calls — see the original comment in git
                // history; Qwen tool-calling works.
                let argsData = (try? JSONSerialization.data(
                    withJSONObject: jsonObject(call.function.arguments)))
                    ?? Data("{}".utf8)
                toolCalls.append(LLMToolCall(
                    name: call.function.name,
                    argumentsJSON: String(decoding: argsData, as: UTF8.self)))
            case .info(let info):
                promptTokens = info.promptTokenCount
                completionTokens = info.generationTokenCount
                tokensPerSecond = info.tokensPerSecond
            }
        }
        // Final safety net — strip any leaked <think>…</think> block.
        let cleaned = request.disableThinking ? stripThinking(rawText) : rawText
        await onEvent(.finished(ChatResult(
            text: cleaned,
            toolCalls: toolCalls,
            usage: ChatUsage(promptTokens: promptTokens,
                             completionTokens: completionTokens),
            wallSeconds: Date().timeIntervalSince(start),
            tokensPerSecond: tokensPerSecond)))
    }

    /// Build an OpenAI-shaped `ToolSpec` ([String: any Sendable]) for the tokenizer.
    private func toolSpec(from tool: LLMTool) throws -> ToolSpec {
        let params = (try? JSONSerialization.jsonObject(with: Data(tool.parametersJSON.utf8)))
            as? [String: any Sendable] ?? [:]
        return [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": params,
            ] as [String: any Sendable],
        ]
    }

    /// Convert tool-call arguments ([String: JSONValue]) into a Foundation object
    /// for JSON serialization (`JSONValue.anyValue` maps each case to Any).
    private func jsonObject(_ args: [String: JSONValue]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in args { out[k] = v.anyValue }
        return out
    }
}
