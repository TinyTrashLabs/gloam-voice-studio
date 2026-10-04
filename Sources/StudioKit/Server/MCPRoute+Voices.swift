import Foundation
import Hummingbird

/// The voice-identity tools: make a voice (designed or from a recording), edit it, give it a face and
/// a second language, and move it in and out as a `.gvoice`. Each mirrors an HTTP route in
/// APIRouter (`POST /voices/design`, `POST /voices`, `PATCH /voices/:slug`, `PUT .../avatar`,
/// `POST .../variants`, `DELETE`, `GET .../export`, `POST /voices/import`) and goes through the same
/// VoiceLibrary calls, so an agent and a curl script get the same rules and the same revision bumps.
extension MCPRoute {
    static let voiceToolNames: Set<String> = [
        "design_voice", "create_voice", "update_voice", "set_avatar",
        "add_language_take", "delete_voice", "export_voice", "import_voice",
    ]

    private static func prop(_ type: String, _ description: String) -> [String: Any] {
        ["type": type, "description": description]
    }

    static var voiceToolDefinitions: [[String: Any]] {
        let personaSchema: [String: Any] = [
            "type": ["object", "null"],
            "description": "Chat persona: {systemPrompt, greeting?, tagline?, catchphrases?, color? (#RRGGBB), "
                + "language?}. Pass null to clear it.",
            "properties": [
                "systemPrompt": ["type": "string"], "greeting": ["type": "string"],
                "tagline": ["type": "string"], "catchphrases": ["type": "array", "items": ["type": "string"]],
                "color": ["type": "string"], "language": ["type": "string"],
            ],
            "required": ["systemPrompt"],
        ]
        return [
            [
                "name": "design_voice",
                "description": "Design a new voice from a description and save it to the library in one call: "
                    + "renders `script` on qwen3-design from `instruct`, keeps the audio and script as the "
                    + "voice's reference. Returns the saved voice's meta (slug, id, revision).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": prop("string", "Display name; its slug becomes the voice's address"),
                        "instruct": prop("string", "The voice, described (\"warm late-night bartender, slow, gravelly\")"),
                        "script": prop("string", "What the voice says in its saved reference (a sentence or two)"),
                        "language": prop("string", "BCP-47 language of the script (optional)"),
                        "persona": personaSchema,
                    ],
                    "required": ["name", "instruct", "script"],
                ],
            ],
            [
                "name": "create_voice",
                "description": "Create a voice from a recording: a WAV file on this Mac plus what it says.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": prop("string", "Display name"),
                        "path": prop("string", "Path to the reference WAV"),
                        "transcript": prop("string", "Exactly what the recording says"),
                    ],
                    "required": ["name", "path", "transcript"],
                ],
            ],
            [
                "name": "update_voice",
                "description": "Edit a voice: rename it, set or clear its persona, set its notes. Only the "
                    + "fields you pass change. Bumps the voice's revision.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "voice": prop("string", "Voice slug from list_voices"),
                        "name": prop("string", "New display name (re-slugs the voice)"),
                        "persona": personaSchema,
                        "notes": prop("string", "Free-form description; \"\" clears it"),
                    ],
                    "required": ["voice"],
                ],
            ],
            [
                "name": "set_avatar",
                "description": "Set a voice's picture from a PNG or JPEG file (stored as a 256x256 PNG).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "voice": prop("string", "Voice slug"),
                        "path": prop("string", "Path to a PNG or JPEG"),
                    ],
                    "required": ["voice", "path"],
                ],
            ],
            [
                "name": "add_language_take",
                "description": "Give a voice a take that speaks another language (e.g. an es recording of a "
                    + "voice). `speak` with that `language` then uses it. Replaces an existing take for the "
                    + "same language.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "voice": prop("string", "Voice slug"),
                        "language": prop("string", "BCP-47 tag, e.g. es or en-US"),
                        "path": prop("string", "Path to the reference WAV in that language"),
                        "transcript": prop("string", "Exactly what the recording says"),
                    ],
                    "required": ["voice", "language", "path", "transcript"],
                ],
            ],
            [
                "name": "delete_voice",
                "description": "Delete a voice and every take inside it. Cannot be undone.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["voice": prop("string", "Voice slug")],
                    "required": ["voice"],
                ],
            ],
            [
                "name": "export_voice",
                "description": "Write a voice (with its takes, persona, avatar, id and revision) to a "
                    + ".gvoice file at `path`.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "voice": prop("string", "Voice slug"),
                        "path": prop("string", "Destination file (a .gvoice extension is added if missing)"),
                    ],
                    "required": ["voice", "path"],
                ],
            ],
            [
                "name": "import_voice",
                "description": "Import a .gvoice file. A pack whose id the library already has is kept as a "
                    + "copy with a new id, unless `update` is true and the pack's revision is higher, in "
                    + "which case it replaces the local voice.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": prop("string", "Path to the .gvoice file"),
                        "update": prop("boolean", "Replace the local voice when the pack is a newer version"),
                    ],
                    "required": ["path"],
                ],
            ],
        ]
    }

    /// A Codable value as JSON-compatible Foundation objects, nil when it is nil or will not encode.
    static func jsonObject<T: Encodable>(_ value: T?) -> Any? {
        guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func metaResult(id: Any?, _ meta: VoiceMeta) -> Response {
        let data = (try? JSONEncoder().encode(meta)) ?? Data("{}".utf8)
        return toolResult(id: id, content: [jsonText(data)])
    }

    private static func file(_ arguments: [String: Any], _ key: String) throws -> Data {
        guard let raw = arguments[key] as? String, !raw.isEmpty else {
            throw APIError(status: .badRequest, detail: "'\(key)' is required")
        }
        let path = (raw as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else {
            throw APIError(status: .badRequest, detail: "cannot read '\(raw)'")
        }
        return data
    }

    private static func string(_ arguments: [String: Any], _ key: String) throws -> String {
        guard let value = arguments[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError(status: .badRequest, detail: "'\(key)' is required")
        }
        return value
    }

    /// `persona` as given: absent = untouched (nil), null = clear (.some(nil)), object = set.
    private static func personaArgument(_ arguments: [String: Any]) throws -> Persona?? {
        guard let raw = arguments["persona"] else { return nil }
        if raw is NSNull { return .some(nil) }
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let persona = try? JSONDecoder().decode(Persona.self, from: data) else {
            throw APIError(status: .badRequest,
                           detail: "persona must be an object with a 'systemPrompt', or null")
        }
        return .some(persona)
    }

    static func callVoiceTool(id: Any?, name: String, arguments: [String: Any],
                              deps: APIDependencies) async -> Response {
        do {
            switch name {
            case "design_voice":
                let design = VoiceDesignRequest(
                    name: try string(arguments, "name"), instruct: try string(arguments, "instruct"),
                    script: try string(arguments, "script"), language: arguments["language"] as? String,
                    persona: try personaArgument(arguments)?.flatMap { $0 })
                return metaResult(id: id, try await APIRouter.designVoice(design, deps: deps))
            case "create_voice":
                let name = try string(arguments, "name")
                let wav = try file(arguments, "path")
                let transcript = try string(arguments, "transcript")
                return metaResult(id: id, try APIRouter.mapStoreErrors {
                    try deps.voices.save(name: name, refWav: wav, refText: transcript)
                })
            case "update_voice":
                let slug = try string(arguments, "voice")
                let newName = (arguments["name"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let notes = arguments["notes"] as? String
                let persona = try personaArgument(arguments)
                return metaResult(id: id, try APIRouter.mapStoreErrors {
                    var meta = try deps.voices.update(
                        slug, name: (newName?.isEmpty == false) ? newName : nil, notes: notes)
                    if let persona { meta = try deps.voices.setPersona(meta.slug, persona: persona) }
                    return meta
                })
            case "set_avatar":
                let slug = try string(arguments, "voice")
                let image = try file(arguments, "path")
                guard AvatarImage.isPNG(image) || AvatarImage.isJPEG(image),
                      let png = AvatarImage.png(from: image) else {
                    throw APIError(status: .badRequest, detail: "'path' is not a PNG or JPEG image")
                }
                return metaResult(id: id, try APIRouter.mapStoreErrors {
                    guard deps.voices.locate(slug) == .voice(slug) else {
                        throw StudioError.voiceNotFound(slug: slug)
                    }
                    try deps.voices.saveAvatar(slug, pngData: png)
                    return try deps.voices.meta(slug)
                })
            case "add_language_take":
                let slug = try string(arguments, "voice")
                let language = try string(arguments, "language")
                guard VoiceLibrary.languageKey(language) != nil else {
                    throw APIError(status: .badRequest,
                                   detail: "language must be a BCP-47 tag such as 'es' or 'en-US'")
                }
                let wav = try file(arguments, "path")
                let transcript = try string(arguments, "transcript")
                return metaResult(id: id, try APIRouter.mapStoreErrors {
                    try deps.voices.addLanguageTake(slug, language: language, refWav: wav, refText: transcript)
                })
            case "delete_voice":
                let slug = try string(arguments, "voice")
                try APIRouter.mapStoreErrors { try deps.voices.delete(slug) }
                return toolResult(id: id, content: [jsonText(Data("{\"ok\":true}".utf8))])
            case "export_voice":
                let slug = try string(arguments, "voice")
                var path = (try string(arguments, "path") as NSString).expandingTildeInPath
                if (path as NSString).pathExtension.isEmpty { path += ".gvoice" }
                let pack = try APIRouter.mapStoreErrors { try GVoice.export(slug, from: deps.voices) }
                try pack.write(to: URL(fileURLWithPath: path))
                return toolResult(id: id, content: [["type": "text",
                                                      "text": "Exported \(slug) (\(pack.count) bytes) → \(path)"]])
            case "import_voice":
                let pack = try file(arguments, "path")
                let update = arguments["update"] as? Bool ?? false
                return metaResult(id: id, try APIRouter.mapStoreErrors {
                    try deps.voices.importPack(pack, update: update)
                })
            default:
                return toolError(id: id, "unknown tool")
            }
        } catch let error as APIError {
            return toolError(id: id, error.detail)
        } catch {
            return toolError(id: id, "\(name) failed: \(error)")
        }
    }
}
