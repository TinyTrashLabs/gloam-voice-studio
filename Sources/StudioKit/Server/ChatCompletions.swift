import EngineKit
import Foundation

struct ChatCompletionRequest: Codable {
    /// One chat message. `content` is either a plain string or, in the
    /// OpenAI vision shape, an array of parts: `{"type":"text","text":…}`
    /// and `{"type":"image_url","image_url":{"url":…}}` where the url is a
    /// `data:` URL (base64 image) or a local `file:` URL. Gemma 4 runs
    /// through the VLM path, so images reach the model; text-only providers
    /// ignore them. Encoding always writes the plain-string form.
    struct Message: Codable {
        let role: String
        let content: String
        /// Image parts, in order, exactly as given (data: or file: URLs).
        let imageURLStrings: [String]

        init(role: String, content: String, imageURLStrings: [String] = []) {
            self.role = role; self.content = content; self.imageURLStrings = imageURLStrings
        }

        private enum CodingKeys: String, CodingKey { case role, content }
        private struct Part: Decodable {
            struct ImageURL: Decodable { let url: String }
            let type: String
            let text: String?
            let image_url: ImageURL?
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            role = try c.decode(String.self, forKey: .role)
            if let plain = try? c.decode(String.self, forKey: .content) {
                content = plain
                imageURLStrings = []
                return
            }
            let parts = try c.decode([Part].self, forKey: .content)
            content = parts.compactMap { $0.type == "text" ? $0.text : nil }.joined(separator: "\n")
            imageURLStrings = parts.compactMap { $0.type == "image_url" ? $0.image_url?.url : nil }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(role, forKey: .role)
            try c.encode(content, forKey: .content)
        }
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
    /// Sampler knobs the engine already supports (mlx-swift-lm natively);
    /// exposed 2026-09-18 because a 4B model behind a heavy persona repeats
    /// itself and the Furby app had no way to ask for variety. OpenAI names
    /// where one exists (presence/frequency), mlx names otherwise.
    let repetition_penalty: Float?
    let repetition_context_size: Int?
    let presence_penalty: Float?
    let frequency_penalty: Float?
    let top_k: Int?
    let min_p: Float?
    /// OpenAI `stream: true` — the reply arrives as server-sent events
    /// (`chat.completion.chunk` deltas, then `[DONE]`), so a caller can start
    /// speaking the first sentence while the model writes the rest.
    let stream: Bool?

    struct BadImage: Error, CustomStringConvertible {
        let description: String
    }

    /// The engine request plus the temp files any `data:` images were
    /// written to (the engine takes file URLs); the caller removes them once
    /// the reply is in. Images are read from the LAST user message only,
    /// which is where the engine attaches them.
    func toChatRequest() throws -> (request: ChatRequest, temporaryFiles: [URL]) {
        let turns: [ChatTurn] = messages.map {
            ChatTurn(role: ChatRole(rawValue: $0.role) ?? .user, content: $0.content)
        }
        let llmTools: [LLMTool]? = tools?.compactMap { t in
            let paramsJSON = t.function.parameters?.jsonString ?? "{}"
            return LLMTool(name: t.function.name,
                           description: t.function.description ?? "",
                           parametersJSON: paramsJSON)
        }
        var imageURLs: [URL] = []
        var temporary: [URL] = []
        if let lastUser = messages.last(where: { $0.role == "user" }) {
            for (i, raw) in lastUser.imageURLStrings.enumerated() {
                if raw.hasPrefix("data:") {
                    let (data, ext) = try Self.decodeDataURL(raw, index: i)
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("gloam-chat-image-\(UUID().uuidString).\(ext)")
                    try data.write(to: url)
                    imageURLs.append(url)
                    temporary.append(url)
                } else if let url = URL(string: raw), url.isFileURL {
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        throw BadImage(description: "image \(i): no file at \(url.path)")
                    }
                    imageURLs.append(url)
                } else {
                    throw BadImage(description: "image \(i): only data: and file: URLs are accepted")
                }
            }
        }
        let request = ChatRequest(
            messages: turns,
            tools: (llmTools?.isEmpty == true) ? nil : llmTools,
            temperature: temperature ?? 0.7,
            topP: top_p,
            maxTokens: max_tokens ?? 512,
            topK: top_k, minP: min_p,
            repetitionPenalty: repetition_penalty, repetitionContextSize: repetition_context_size,
            presencePenalty: presence_penalty, frequencyPenalty: frequency_penalty,
            disableThinking: true,   // brain never wants reasoning
            imageURLs: imageURLs.isEmpty ? nil : imageURLs)
        return (request, temporary)
    }

    /// `data:image/jpeg;base64,…` → bytes and a file extension for the MIME type.
    static func decodeDataURL(_ raw: String, index: Int) throws -> (Data, String) {
        guard let comma = raw.firstIndex(of: ",") else {
            throw BadImage(description: "image \(index): malformed data URL")
        }
        let header = raw[raw.index(raw.startIndex, offsetBy: 5) ..< comma]   // after "data:"
        guard header.hasSuffix(";base64") else {
            throw BadImage(description: "image \(index): data URL must be base64")
        }
        let mime = header.dropLast(";base64".count)
        let ext: String = switch mime {
        case "image/png": "png"
        case "image/jpeg", "image/jpg": "jpg"
        case "image/webp": "webp"
        case "image/gif": "gif"
        case "image/heic": "heic"
        default: throw BadImage(description: "image \(index): unsupported type \(mime)")
        }
        guard let data = Data(base64Encoded: String(raw[raw.index(after: comma)...]),
                              options: .ignoreUnknownCharacters), !data.isEmpty else {
            throw BadImage(description: "image \(index): base64 did not decode")
        }
        return (data, ext)
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

/// One SSE frame of a streamed completion, in the OpenAI `chat.completion.chunk`
/// shape. `delta.content` carries text; the last chunk has an empty delta,
/// `finish_reason: "stop"` and the usage.
struct ChatCompletionChunk: Codable {
    struct Choice: Codable {
        struct Delta: Codable { let role: String?; let content: String? }
        let index: Int
        let delta: Delta
        let finish_reason: String?
    }
    let object: String
    let model: String
    let choices: [Choice]
    let usage: ChatCompletionResponse.Usage?

    static func delta(model: String, text: String, first: Bool) -> ChatCompletionChunk {
        ChatCompletionChunk(object: "chat.completion.chunk", model: model,
                            choices: [Choice(index: 0, delta: .init(role: first ? "assistant" : nil, content: text),
                                             finish_reason: nil)],
                            usage: nil)
    }

    static func stop(model: String, promptTokens: Int, completionTokens: Int) -> ChatCompletionChunk {
        ChatCompletionChunk(object: "chat.completion.chunk", model: model,
                            choices: [Choice(index: 0, delta: .init(role: nil, content: nil), finish_reason: "stop")],
                            usage: .init(prompt_tokens: promptTokens, completion_tokens: completionTokens,
                                         total_tokens: promptTokens + completionTokens))
    }

    /// `data: {json}\n\n`
    func sseFrame() throws -> String {
        "data: " + String(decoding: try JSONEncoder().encode(self), as: UTF8.self) + "\n\n"
    }
}
