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

    public init(messages: [ChatTurn], tools: [LLMTool]? = nil,
                temperature: Float = 0.7, topP: Float? = nil,
                maxTokens: Int = 512,
                topK: Int? = nil, minP: Float? = nil,
                repetitionPenalty: Float? = nil, repetitionContextSize: Int? = nil,
                presencePenalty: Float? = nil, frequencyPenalty: Float? = nil,
                disableThinking: Bool = true) {
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

/// A loaded language model. Conformers handle their own thread-safety
/// (`Sendable`); GloamEngine serializes all calls through its task chain.
public protocol LanguageModel: AnyObject, Sendable {
    func complete(_ request: ChatRequest) async throws -> ChatResult
}

/// Loads language models. Real impl wraps mlx-swift-lm; tests use fakes.
public protocol LanguageModelProviding: Sendable {
    func loadModel(backend: LLMBackendID) async throws -> any LanguageModel
    func didEvictModel()
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
