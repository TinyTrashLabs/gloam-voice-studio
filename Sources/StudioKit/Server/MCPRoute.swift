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
                return jsonRPCResult(id: id, ["tools": toolDefinitions(deps: deps)])
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

    /// The advertised surface. The six `lab_*` tools are appended only when the
    /// server was built with a Lab store (Settings → Storage → Advanced): with
    /// Lab off an agent must not even see them, let alone be able to call them.
    private static func toolDefinitions(deps: APIDependencies) -> [[String: Any]] {
        var tools: [[String: Any]] = [
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
        guard deps.lab != nil else { return tools }
        tools += [
            [
                "name": "lab_set_group",
                "description": "Create or update a Lab comparison group (the unit "
                    + "the audio-comparison shelf collects clips into). Pass `id` to "
                    + "update an existing group's heading/listen_for; omit it to create.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "heading": ["type": "string",
                                    "description": "What's being compared"],
                        "listen_for": ["type": "string",
                                       "description": "Instruction to the listener (optional)"],
                        "id": ["type": "string",
                               "description": "Existing group id to update (optional)"],
                    ],
                    "required": ["heading"],
                ],
            ],
            [
                "name": "lab_put_clip",
                "description": "Add a WAV to a Lab group and return its clip id and "
                    + "duration. Address the group by `group_id`, or by `group_heading` "
                    + "(created if absent). Supply the audio as `audio_b64` (inline "
                    + "base64 WAV) or `path` (a local file the app can read).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "group_id": ["type": "string",
                                     "description": "Target group id"],
                        "group_heading": ["type": "string",
                                          "description": "Target group by heading (create-if-absent)"],
                        "label": ["type": "string",
                                  "description": "Clip label (\"A · Benson's original 8s ref\")"],
                        "note": ["type": "string",
                                 "description": "Per-clip note (optional)"],
                        "audio_b64": ["type": "string",
                                      "description": "Base64-encoded WAV bytes"],
                        "path": ["type": "string",
                                 "description": "Path to a local WAV to copy in"],
                    ],
                    "required": ["label"],
                ],
            ],
            [
                "name": "lab_list",
                "description": "List all Lab groups with their clips "
                    + "(id, label, duration, source).",
                "inputSchema": ["type": "object", "properties": [String: Any]()],
            ],
            [
                "name": "lab_read_feedback",
                "description": "Read back what the developer left on the Lab: per-clip "
                    + "timestamp marks and comments, per-group verdict, and open "
                    + "requests. Pass `group_id` for one group, omit for all.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "group_id": ["type": "string",
                                     "description": "Limit to one group (optional)"],
                    ],
                ],
            ],
            [
                "name": "lab_delete_group",
                "description": "Delete a Lab group and its clips.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "group_id": ["type": "string", "description": "Group id to delete"],
                    ],
                    "required": ["group_id"],
                ],
            ],
            [
                "name": "lab_delete_clip",
                "description": "Delete a single Lab clip.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "clip_id": ["type": "string", "description": "Clip id to delete"],
                    ],
                    "required": ["clip_id"],
                ],
            ],
        ]
        return tools
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
            let backend = deps.defaultBackend
            let controls = backend.controls
            // CONTRACT (matches /v1/audio/speech — PR #38 "400 on an unresolvable
            // voice instead of inventing a speaker"): on a cloning backend this tool
            // never synthesizes without a resolved reference. An unknown voice, an
            // omitted voice with no default configured, or a resolved voice whose
            // meta.json carries an empty transcript (on backends whose clone path is
            // conditioned on text too — BackendID.needsRefText) used to leave
            // refPath/refText nil with zero gating, falling into the model's
            // UNCONDITIONED branch and inventing a random speaker while reporting
            // success. Refuse explicitly instead, same as the HTTP endpoint.
            let clones = controls.voiceClone != .none
            let effectiveVoice = (arguments["voice"] as? String) ?? {
                let def = deps.defaultVoice()
                return def.isEmpty ? nil : def
            }()
            let resolved: (path: String, text: String?)?
            if let voice = effectiveVoice {
                guard let found = try? deps.voices.get(voice) else {
                    APIRouter.logError("mcp speak: voice '\(voice)' not found"
                        + " (model \(backend.rawValue)) — refusing to synthesize an"
                        + " unconditioned, randomly invented speaker")
                    return toolError(id: id, "voice '\(voice)' not found — call list_voices")
                }
                if clones && backend.needsRefText && found.meta.refText.isEmpty {
                    APIRouter.logError("mcp speak: voice '\(voice)' has an empty refText"
                        + " (model \(backend.rawValue)) — refusing to synthesize an"
                        + " unconditioned, randomly invented speaker")
                    return toolError(id: id, "voice '\(voice)' has an empty reference"
                        + " transcript — \(backend.rawValue) cannot clone from it")
                }
                resolved = (found.refURL.path,
                            found.meta.refText.isEmpty ? nil : found.meta.refText)
            } else if clones {
                APIRouter.logError("mcp speak: no voice given and no default voice is set"
                    + " (model \(backend.rawValue)) — refusing to synthesize an"
                    + " unconditioned, randomly invented speaker")
                return toolError(id: id, "\(backend.rawValue) requires a 'voice' — call list_voices")
            } else {
                resolved = nil
            }
            let refPath = resolved?.path
            let refText = resolved?.text
            let emotion = (arguments["emotion"] as? String)
                .flatMap(Emotion.init(rawValue:)) ?? .neutral
            do {
                let result = try await deps.gate.run {
                    await deps.prepareTTS()
                    return try await deps.engine.synthesize(
                        backend: backend,
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
        case "lab_set_group":
            guard let heading = arguments["heading"] as? String else {
                return toolError(id: id, "lab_set_group requires 'heading'")
            }
            // Pull the args into local Sendable values before the main-actor hop —
            // the raw `arguments` dictionary is task-isolated and can't cross it.
            let listenFor = arguments["listen_for"] as? String ?? ""
            let groupID = arguments["id"] as? String
            do {
                let out = try await MainActor.run {
                    try LabTools.setGroup(try LabTools.store(deps), heading: heading,
                                          listenFor: listenFor, id: groupID)
                }
                return toolResult(id: id, content: [jsonText(out)])
            } catch {
                return toolError(id: id, "\(error)")
            }
        case "lab_put_clip":
            guard let label = arguments["label"] as? String else {
                return toolError(id: id, "lab_put_clip requires 'label'")
            }
            let groupID = arguments["group_id"] as? String
            let groupHeading = arguments["group_heading"] as? String
            let note = arguments["note"] as? String
            let audioB64 = arguments["audio_b64"] as? String
            let path = arguments["path"] as? String
            do {
                let out = try await MainActor.run {
                    try LabTools.putClip(try LabTools.store(deps),
                                         groupID: groupID, groupHeading: groupHeading,
                                         label: label, note: note,
                                         audioB64: audioB64, path: path, source: .mcp)
                }
                return toolResult(id: id, content: [jsonText(out)])
            } catch {
                return toolError(id: id, "\(error)")
            }
        case "lab_list":
            do {
                let out = try await MainActor.run { LabTools.list(try LabTools.store(deps)) }
                return toolResult(id: id, content: [jsonText(out)])
            } catch {
                return toolError(id: id, "\(error)")
            }
        case "lab_read_feedback":
            let groupID = arguments["group_id"] as? String
            do {
                let data = try await MainActor.run {
                    try LabTools.feedbackJSON(try LabTools.store(deps), groupID: groupID)
                }
                return toolResult(id: id, content: [
                    ["type": "text", "text": String(decoding: data, as: UTF8.self)],
                ])
            } catch {
                return toolError(id: id, "\(error)")
            }
        case "lab_delete_group":
            guard let groupID = arguments["group_id"] as? String else {
                return toolError(id: id, "lab_delete_group requires 'group_id'")
            }
            do {
                try await MainActor.run { try LabTools.deleteGroup(try LabTools.store(deps), groupID: groupID) }
                return toolResult(id: id, content: [jsonText(Data("{\"ok\":true}".utf8))])
            } catch {
                return toolError(id: id, "\(error)")
            }
        case "lab_delete_clip":
            guard let clipID = arguments["clip_id"] as? String else {
                return toolError(id: id, "lab_delete_clip requires 'clip_id'")
            }
            do {
                try await MainActor.run { try LabTools.deleteClip(try LabTools.store(deps), clipID: clipID) }
                return toolResult(id: id, content: [jsonText(Data("{\"ok\":true}".utf8))])
            } catch {
                return toolError(id: id, "\(error)")
            }
        default:
            return toolError(id: id, "unknown tool")
        }
    }

    /// Wraps already-serialized JSON bytes as a `text` tool-result content block
    /// (MCP has no first-class JSON content type).
    private static func jsonText(_ data: Data) -> [String: Any] {
        ["type": "text", "text": String(decoding: data, as: UTF8.self)]
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
