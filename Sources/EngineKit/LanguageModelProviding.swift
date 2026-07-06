import Foundation

public enum ChatRole: String, Sendable, Codable {
    case system, user, assistant, tool
}

public struct ChatTurn: Sendable, Equatable, Codable {
    public var role: ChatRole
    public var content: String
    public init(role: ChatRole, content: String) {
        self.role = role
        self.content = content
    }
}

/// A tool/function definition, OpenAI-shaped. `parametersJSON` is the raw JSON
/// string of the parameters schema, kept opaque here; the provider hands it to
/// the tokenizer as-is.
public struct LLMTool: Sendable, Equatable, Codable {
    public var name: String
    public var description: String
    public var parametersJSON: String
    public init(name: String, description: String, parametersJSON: String) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }
}

public struct LLMToolCall: Sendable, Equatable, Codable {
    public var name: String
    public var argumentsJSON: String
    public init(name: String, argumentsJSON: String) {
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public struct ChatRequest: Sendable, Equatable {
    public var messages: [ChatTurn]
    public var tools: [LLMTool]?
    public var temperature: Float
    public var topP: Float?
    public var maxTokens: Int
    // Advanced sampler surface (nil = library default). Exposed by the chat
    // inspector's Advanced disclosure; all natively supported by mlx-swift-lm.
    public var topK: Int?
    public var minP: Float?
    public var repetitionPenalty: Float?
    public var repetitionContextSize: Int?
    public var presencePenalty: Float?
    public var frequencyPenalty: Float?
    /// Hard-off thinking by default (DJ brain never wants reasoning tokens).
    public var disableThinking: Bool
    /// Images attached to the FINAL user turn (vision models only; ignored by
    /// text-only providers). Local file URLs.
    public var imageURLs: [URL]?

    public init(messages: [ChatTurn], tools: [LLMTool]? = nil,
                temperature: Float = 0.7, topP: Float? = nil,
                maxTokens: Int = 512,
                topK: Int? = nil, minP: Float? = nil,
                repetitionPenalty: Float? = nil, repetitionContextSize: Int? = nil,
                presencePenalty: Float? = nil, frequencyPenalty: Float? = nil,
                disableThinking: Bool = true,
                imageURLs: [URL]? = nil) {
        self.messages = messages
        self.tools = tools
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.topK = topK
        self.minP = minP
        self.repetitionPenalty = repetitionPenalty
        self.repetitionContextSize = repetitionContextSize
        self.presencePenalty = presencePenalty
        self.frequencyPenalty = frequencyPenalty
        self.disableThinking = disableThinking
        self.imageURLs = imageURLs
    }
}

public struct ChatUsage: Sendable, Equatable {
    public var promptTokens: Int
    public var completionTokens: Int
    public init(promptTokens: Int, completionTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

public struct ChatResult: Sendable {
    public var text: String
    public var toolCalls: [LLMToolCall]
    public var usage: ChatUsage
    public var wallSeconds: Double
    /// Generation speed reported by the provider (nil for fakes/older paths).
    public var tokensPerSecond: Double?
    public init(text: String, toolCalls: [LLMToolCall], usage: ChatUsage,
                wallSeconds: Double, tokensPerSecond: Double? = nil) {
        self.text = text
        self.toolCalls = toolCalls
        self.usage = usage
        self.wallSeconds = wallSeconds
        self.tokensPerSecond = tokensPerSecond
    }
}

/// One streaming chat event: incremental text, then a final result. The final
/// text in `.finished` is authoritative (it's cleaned via stripThinking); UIs
/// should replace accumulated deltas with it.
public enum ChatEvent: Sendable {
    case delta(String)
    case finished(ChatResult)
}

/// A loaded language model. Conformers handle their own thread-safety
/// (`Sendable`); GloamEngine serializes all calls through its task chain.
public protocol LanguageModel: AnyObject, Sendable {
    func complete(_ request: ChatRequest) async throws -> ChatResult
    /// Streaming variant. Implementations must yield `.finished` exactly once,
    /// as the last event before finishing.
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
    /// Consumer-paced streaming: `onEvent` is awaited for every event and the
    /// model performs no further generation work until it returns. This is the
    /// engine's interleave point — queued TTS synthesis runs between deltas
    /// while the GPU is otherwise idle, keeping all GPU work serialized.
    /// Implementations must deliver `.finished` exactly once, as the last event.
    func pacedStream(_ request: ChatRequest,
                     onEvent: @Sendable (ChatEvent) async -> Void) async throws

    /// Blocks until any speculative computation the model pipelined ahead has
    /// completed (MLX's TokenIterator launches the NEXT token's eval before
    /// returning the current one). The engine calls this before running other
    /// GPU work in a between-deltas gap so the two never overlap. No-op for
    /// models that don't pipeline.
    func awaitPendingComputation() async
}

public extension LanguageModel {
    /// Non-streaming models emit their whole reply as one delta + finished.
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await self.complete(request)
                    continuation.yield(.delta(result.text))
                    continuation.yield(.finished(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Fallback pacing: forward the (possibly free-running) stream, awaiting
    /// the handler per event. True pacing needs a pull-based implementation;
    /// this keeps fakes and simple conformers correct.
    func pacedStream(_ request: ChatRequest,
                     onEvent: @Sendable (ChatEvent) async -> Void) async throws {
        for try await event in stream(request) {
            try Task.checkCancellation()
            await onEvent(event)
        }
    }

    func awaitPendingComputation() async {}
}

/// Loads language models. Real impl wraps mlx-swift-lm; tests use fakes.
public protocol LanguageModelProviding: Sendable {
    func loadModel(backend: LLMBackendID) async throws -> any LanguageModel
    func didEvictModel()
}

/// Split a reply into its `<think>` reasoning and the visible answer, for UIs
/// that show reasoning collapsed. An unterminated `<think>` (still streaming)
/// yields everything so far as reasoning and an empty answer.
public func splitThinking(_ text: String) -> (thinking: String?, answer: String) {
    guard let open = text.range(of: "<think>") else {
        return (nil, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    if let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
        let thinking = String(text[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (thinking.isEmpty ? nil : thinking, stripThinking(text))
    }
    let thinking = String(text[open.upperBound...])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let before = String(text[..<open.lowerBound])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return (thinking.isEmpty ? nil : thinking, before)
}

/// Safety net: strip any `<think>…</think>` reasoning block so it can never leak
/// into banter, even if suppression partially fails. An unterminated `<think>`
/// drops everything from the tag onward.
public func stripThinking(_ text: String) -> String {
    var out = text
    while let open = out.range(of: "<think>") {
        if let close = out.range(of: "</think>", range: open.upperBound..<out.endIndex) {
            out.removeSubrange(open.lowerBound..<close.upperBound)
        } else {
            out.removeSubrange(open.lowerBound..<out.endIndex)
        }
    }
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
}
