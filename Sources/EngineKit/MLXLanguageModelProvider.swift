import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
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
        let configuration = ModelConfiguration(directory: dir)
        // `#huggingFaceLoadModelContainer` expands to `loadModelContainer(from:
        // #hubDownloader(), using: #huggingFaceTokenizerLoader(), configuration:)`.
        // For a `.directory` configuration the downloader is never invoked (resolve
        // short-circuits to the local path); only the tokenizer loader runs against
        // the on-disk folder.
        let container = try await #huggingFaceLoadModelContainer(configuration: configuration)
        return MLXLanguageModel(container: container, family: backend.family)
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

    func complete(_ request: ChatRequest) async throws -> ChatResult {
        let start = Date()

        // 1. Thinking-off via tokenizer chat-template flag.
        var additionalContext: [String: any Sendable] = [:]
        if request.disableThinking { additionalContext["enable_thinking"] = false }

        var turns = request.messages
        let systemText = turns.first(where: { $0.role == .system })?.content
        turns.removeAll { $0.role == .system }

        // 2. (Gemma) reinforce "no reasoning" in the system instructions.
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

        let history: [Chat.Message] = turns.map { turn in
            switch turn.role {
            case .assistant: return .assistant(turn.content)
            case .user: return .user(turn.content)
            case .tool: return .tool(turn.content)
            case .system: return .system(turn.content)
            }
        }

        let params = GenerateParameters(
            maxTokens: request.maxTokens,
            temperature: request.temperature,
            topP: request.topP ?? 1.0)

        let toolSpecs: [ToolSpec]? = try request.tools.map { try $0.map { try toolSpec(from: $0) } }

        let session = ChatSession(
            container,
            instructions: instructions,
            history: history,
            generateParameters: params,
            additionalContext: additionalContext.isEmpty ? nil : additionalContext,
            tools: toolSpecs)

        var rawText = ""
        var toolCalls: [LLMToolCall] = []
        var promptTokens = 0
        var completionTokens = 0

        for try await generation in session.streamDetails(to: lastUser, images: [], videos: []) {
            switch generation {
            case .chunk(let t):
                rawText += t
            case .toolCall(let call):
                let argsData = (try? JSONSerialization.data(
                    withJSONObject: jsonObject(call.function.arguments))) ?? Data("{}".utf8)
                toolCalls.append(LLMToolCall(
                    name: call.function.name,
                    argumentsJSON: String(decoding: argsData, as: UTF8.self)))
            case .info(let info):
                promptTokens = info.promptTokenCount
                completionTokens = info.generationTokenCount
            }
        }

        // 4. Final safety net — strip any leaked <think>…</think> block.
        let cleaned = request.disableThinking ? stripThinking(rawText) : rawText

        return ChatResult(
            text: cleaned,
            toolCalls: toolCalls,
            usage: ChatUsage(promptTokens: promptTokens, completionTokens: completionTokens),
            wallSeconds: Date().timeIntervalSince(start))
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
