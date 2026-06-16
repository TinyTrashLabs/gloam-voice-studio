import EngineKit
import Foundation

struct ChatCompletionRequest: Codable {
    struct Message: Codable {
        let role: String
        let content: String
    }
    struct Tool: Codable {
        struct Function: Codable {
            let name: String
            let description: String?
            let parameters: AnyCodableJSON?
        }
        let type: String?
        let function: Function
    }
    let model: String?
    let messages: [Message]
    let temperature: Float?
    let top_p: Float?
    let max_tokens: Int?
    let tools: [Tool]?

    func toChatRequest() -> ChatRequest {
        let turns: [ChatTurn] = messages.map {
            ChatTurn(role: ChatRole(rawValue: $0.role) ?? .user, content: $0.content)
        }
        let llmTools: [LLMTool]? = tools?.compactMap { t in
            let paramsJSON = t.function.parameters?.jsonString ?? "{}"
            return LLMTool(name: t.function.name,
                           description: t.function.description ?? "",
                           parametersJSON: paramsJSON)
        }
        return ChatRequest(
            messages: turns,
            tools: (llmTools?.isEmpty == true) ? nil : llmTools,
            temperature: temperature ?? 0.7,
            topP: top_p,
            maxTokens: max_tokens ?? 512,
            disableThinking: true)   // brain never wants reasoning
    }
}

struct ChatCompletionResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable { let role: String; let content: String }
        let index: Int
        let message: Message
        let finish_reason: String
    }
    struct Usage: Codable {
        let prompt_tokens: Int
        let completion_tokens: Int
        let total_tokens: Int
    }
    let object: String
    let model: String
    let choices: [Choice]
    let usage: Usage

    init(model: String, content: String, promptTokens: Int, completionTokens: Int) {
        self.object = "chat.completion"
        self.model = model
        self.choices = [Choice(index: 0,
                               message: .init(role: "assistant", content: content),
                               finish_reason: "stop")]
        self.usage = Usage(prompt_tokens: promptTokens,
                           completion_tokens: completionTokens,
                           total_tokens: promptTokens + completionTokens)
    }
}

/// Minimal type that round-trips an arbitrary JSON value (used for tool
/// `parameters` schemas) and can re-serialize it to a JSON string.
struct AnyCodableJSON: Codable {
    let value: Any
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode([String: AnyCodableJSON].self) {
            value = v.mapValues { $0.value }
        } else if let v = try? c.decode([AnyCodableJSON].self) {
            value = v.map { $0.value }
        } else if let v = try? c.decode(Bool.self) { value = v }
        else if let v = try? c.decode(Int.self) { value = v }
        else if let v = try? c.decode(Double.self) { value = v }
        else if let v = try? c.decode(String.self) { value = v }
        else { value = NSNull() }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(jsonString)
    }
    var jsonString: String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value)
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
