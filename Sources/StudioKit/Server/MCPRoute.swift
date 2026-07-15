import EngineKit
import Foundation
import Hummingbird

/// Minimal Model Context Protocol server (Streamable HTTP transport,
/// stateless JSON responses) mounted at /mcp — lets any MCP-aware agent
/// (Claude Code, Cursor, VS Code, …) browse the voice library and speak text
/// in a cloned voice. Tool surface modeled on Voicebox's MCP server (MIT);
/// implementation is ours.
///
/// Scope: request/response JSON only — no SSE stream, no sessions, no
/// server-initiated messages. That is a valid minimal Streamable HTTP server:
/// clients POST JSON-RPC and read the JSON reply.
enum MCPRoute {
    static let protocolVersion = "2025-06-18"

    static func add(to router: Router<BasicRequestContext>, deps: APIDependencies) {
        router.post("mcp") { request, context -> Response in
            var buffer = try await request.body.collect(upTo: 4 * 1024 * 1024)
            guard let data = buffer.readData(length: buffer.readableBytes),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return jsonRPCError(id: nil, code: -32700, message: "parse error")
            }
            let id = message["id"]
            guard let method = message["method"] as? String else {
                return jsonRPCError(id: id, code: -32600, message: "missing method")
            }
            // Notifications (no id) are acknowledged and ignored.
            if id == nil || method.hasPrefix("notifications/") {
                return Response(status: .accepted)
            }
            let params = message["params"] as? [String: Any] ?? [:]

            switch method {
            case "initialize":
                return jsonRPCResult(id: id, [
                    "protocolVersion": protocolVersion,
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": "gloam-voice-studio", "version": "0.1.0"],
                ])
            case "ping":
                return jsonRPCResult(id: id, [String: Any]())
            case "tools/list":
                return jsonRPCResult(id: id, ["tools": toolDefinitions()])
            case "tools/call":
                return await callTool(id: id, params: params, deps: deps)
            default:
                return jsonRPCError(id: id, code: -32601, message: "method not found: \(method)")
            }
        }
        // No SSE stream in this minimal server.
        router.get("mcp") { _, _ in Response(status: .methodNotAllowed) }
    }

    // MARK: tools

    private static func toolDefinitions() -> [[String: Any]] {
        [
            [
                "name": "list_voices",
                "description": "List the cloned voices in the Gloam library "
                    + "(slug, display name, whether a chat persona is set).",
                "inputSchema": ["type": "object", "properties": [String: Any]()],
            ],
            [
                "name": "speak",
                "description": "Synthesize text in a cloned voice; returns the "
                    + "WAV as audio content plus the file path it was written to.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "What to say"],
                        "voice": ["type": "string",
                                  "description": "Voice slug from list_voices (optional)"],
                        "emotion": ["type": "string",
                                    "description": "flat|neutral|warm|excited|hype (optional)"],
                    ],
                    "required": ["text"],
                ],
            ],
            [
                "name": "transcribe",
                "description": "Transcribe speech from a base64-encoded WAV to "
                    + "text using the studio's native on-device recognizer.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "audio": ["type": "string",
                                  "description": "Base64-encoded WAV audio to transcribe"],
                        "language": ["type": "string",
                                     "description": "BCP-47 language hint (optional)"],
                    ],
                    "required": ["audio"],
                ],
            ],
            [
                "name": "listen",
                "description": "Open the microphone, listen for one spoken "
                    + "utterance, and return the transcript (native on-device "
                    + "recognition). Blocks until you stop speaking.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "maxSeconds": ["type": "number",
                                       "description": "Hard cap on recording length (default 30)"],
                        "silenceSeconds": ["type": "number",
                                           "description": "Trailing silence that ends the turn (default 1.2)"],
                        "language": ["type": "string",
                                     "description": "BCP-47 language hint (optional)"],
                    ],
                ],
            ],
        ]
    }

    private static func callTool(id: Any?, params: [String: Any],
                                 deps: APIDependencies) async -> Response {
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        switch params["name"] as? String {
        case "list_voices":
            let voices = deps.voices.list().map { meta -> [String: Any] in
                ["slug": meta.slug, "name": meta.name,
                 "hasPersona": meta.persona != nil]
            }
            let json = (try? JSONSerialization.data(
                withJSONObject: voices, options: [.prettyPrinted])) ?? Data("[]".utf8)
            return toolResult(id: id, content: [
                ["type": "text", "text": String(decoding: json, as: UTF8.self)],
            ])
        case "speak":
            guard let text = arguments["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return toolError(id: id, "speak requires non-empty 'text'")
            }
            let resolved: (path: String, text: String?)?
            if let voice = arguments["voice"] as? String {
                guard let found = try? deps.voices.get(voice) else {
                    return toolError(id: id, "voice '\(voice)' not found — call list_voices")
                }
                resolved = (found.refURL.path,
                            found.meta.refText.isEmpty ? nil : found.meta.refText)
            } else {
                resolved = nil
            }
            let refPath = resolved?.path
            let refText = resolved?.text
            let emotion = (arguments["emotion"] as? String)
                .flatMap(Emotion.init(rawValue:)) ?? .neutral
            do {
                let result = try await deps.gate.run {
                    try await deps.engine.synthesize(
                        backend: deps.defaultBackend,
                        request: SynthesisRequest(
                            text: text, refAudioPath: refPath, refText: refText,
                            emotion: emotion, speed: 1.0))
                }
                let wav = WAVEncoder.encode(
                    pcm16: PCM16.data(from: AudioAssembler.normalizePeak(floats: result.samples)),
                    sampleRate: result.sampleRate)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("gloam-mcp-\(UUID().uuidString).wav")
                try? wav.write(to: url)
                var content: [[String: Any]] = [[
                    "type": "text",
                    "text": String(format: "Spoke %.1fs of audio → %@",
                                   Double(result.samples.count) / Double(result.sampleRate),
                                   url.path),
                ]]
                // Inline the audio when it's a sane size for a tool result.
                if wav.count < 4 * 1024 * 1024 {
                    content.append(["type": "audio",
                                    "data": wav.base64EncodedString(),
                                    "mimeType": "audio/wav"])
                }
                return toolResult(id: id, content: content)
            } catch {
                return toolError(id: id, "synthesis failed: \(error)")
            }
        case "transcribe":
            guard let b64 = arguments["audio"] as? String,
                  let audio = Data(base64Encoded: b64), !audio.isEmpty else {
                return toolError(id: id, "transcribe requires base64 'audio' (wav)")
            }
            let language = arguments["language"] as? String
            do {
                let text = try await deps.gate.run {
                    try await deps.transcribe(audio, language)
                }
                return toolResult(id: id, content: [["type": "text", "text": text]])
            } catch {
                return toolError(id: id, "transcription failed: \(error)")
            }
        case "listen":
            let maxSeconds = (arguments["maxSeconds"] as? NSNumber)?.doubleValue ?? 30
            let silenceSeconds = (arguments["silenceSeconds"] as? NSNumber)?.doubleValue ?? 1.2
            let language = arguments["language"] as? String
            do {
                let text = try await deps.gate.run {
                    try await deps.listen(maxSeconds, silenceSeconds, language)
                }
                return toolResult(id: id, content: [["type": "text", "text": text]])
            } catch {
                return toolError(id: id, "listen failed: \(error)")
            }
        default:
            return toolError(id: id, "unknown tool")
        }
    }

    // MARK: JSON-RPC plumbing

    private static func toolResult(id: Any?, content: [[String: Any]]) -> Response {
        jsonRPCResult(id: id, ["content": content, "isError": false])
    }

    private static func toolError(id: Any?, _ message: String) -> Response {
        jsonRPCResult(id: id, [
            "content": [["type": "text", "text": message]],
            "isError": true,
        ])
    }

    private static func jsonRPCResult(id: Any?, _ result: [String: Any]) -> Response {
        respond(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private static func jsonRPCError(id: Any?, code: Int, message: String) -> Response {
        respond(["jsonrpc": "2.0", "id": id ?? NSNull(),
                 "error": ["code": code, "message": message]])
    }

    private static func respond(_ object: [String: Any]) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: data)))
    }
}
