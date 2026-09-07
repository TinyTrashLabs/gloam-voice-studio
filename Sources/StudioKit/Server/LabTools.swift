import Foundation

/// Core logic behind the Lab MCP tools and the mirrored `/v1/lab/*` HTTP routes.
/// Both surfaces speak the same JSON in and out, so the actual store work lives
/// here once. Every function is `@MainActor` because `LabStore` is -- the MCP
/// handler and the HTTP handler each hop to the main actor to call in.
///
/// Errors are surfaced as `LabToolError`: `.badInput` for a caller mistake
/// (missing/ambiguous argument), `.unknownGroup` when a named group can't be
/// resolved. The MCP layer turns both into an `isError: true` tool result; the
/// HTTP layer turns both into a 4xx.
enum LabTools {
    enum Error: Swift.Error, CustomStringConvertible {
        case badInput(String)
        case unknownGroup(String)
        var description: String {
            switch self {
            case .badInput(let m): return m
            case .unknownGroup(let id): return "no Lab group with id '\(id)'"
            }
        }
    }

    /// The store the handlers operate on: the injected one, else the app-wide shared.
    @MainActor
    static func store(_ deps: APIDependencies) -> LabStore {
        deps.lab ?? LabStore.shared
    }

    /// Serialize a JSON object to `Data`. Returned by the functions below so the
    /// result crossing the main-actor boundary is `Sendable` (a `[String: Any]`
    /// is not).
    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object,
                                     options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }

    // MARK: set_group

    /// Create a group, or update an existing one addressed by `id`. Returns the
    /// group's id + heading.
    @MainActor
    static func setGroup(_ store: LabStore, heading: String,
                         listenFor: String, id: String?) throws -> Data {
        let trimmed = heading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Error.badInput("lab_set_group requires 'heading'") }
        let group = store.setGroup(id: id, heading: trimmed, listenFor: listenFor)
        return json(["id": group.id, "heading": group.heading])
    }

    // MARK: put_clip

    /// Copy a WAV (base64 or a local path) into a group -- addressed by id, or by
    /// heading via `ensureGroup` (create-if-absent). Returns the new clip id +
    /// duration.
    @MainActor
    static func putClip(_ store: LabStore, groupID: String?, groupHeading: String?,
                        label: String, note: String?, audioB64: String?,
                        path: String?, source: LabClipSource) throws -> Data {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else { throw Error.badInput("lab_put_clip requires 'label'") }

        // Resolve the audio bytes: inline base64 wins, else read the file at path.
        let wav: Data
        if let audioB64, !audioB64.isEmpty {
            guard let decoded = Data(base64Encoded: audioB64) else {
                throw Error.badInput("audio_b64 is not valid base64")
            }
            wav = decoded
        } else if let path, !path.isEmpty {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                throw Error.badInput("could not read a WAV at path '\(path)'")
            }
            wav = data
        } else {
            throw Error.badInput("lab_put_clip requires 'audio_b64' or 'path'")
        }

        // Resolve the group: an explicit id must already exist; a heading is
        // created if absent.
        let resolvedID: String
        if let groupID, !groupID.isEmpty {
            guard store.group(groupID) != nil else { throw Error.unknownGroup(groupID) }
            resolvedID = groupID
        } else if let groupHeading, !groupHeading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedID = store.ensureGroup(heading: groupHeading).id
        } else {
            throw Error.badInput("lab_put_clip requires 'group_id' or 'group_heading'")
        }

        do {
            let clip = try store.putClip(groupID: resolvedID, label: trimmedLabel,
                                         note: note, wav: wav, source: source)
            return json(["clip_id": clip.id, "duration": clip.duration ?? 0])
        } catch let LabError.unknownGroup(id) {
            throw Error.unknownGroup(id)
        }
    }

    // MARK: list

    /// All groups with their clips (id, label, duration, source), built from the
    /// live store state.
    @MainActor
    static func list(_ store: LabStore) -> Data {
        let state = store.state
        let groups: [[String: Any]] = state.groups.map { g in
            [
                "id": g.id,
                "heading": g.heading,
                "listen_for": g.listenFor,
                "verdict": g.verdict.map { $0 as Any } ?? NSNull(),
                "clips": state.clips(of: g).map { c -> [String: Any] in
                    [
                        "id": c.id,
                        "label": c.label,
                        "duration": c.duration ?? 0,
                        "source": c.source.rawValue,
                    ]
                },
            ]
        }
        return json(["groups": groups])
    }

    // MARK: read_feedback

    /// JSON (pretty) of everything the developer left, for one group or all.
    @MainActor
    static func feedbackJSON(_ store: LabStore, groupID: String?) throws -> Data {
        let feedback = store.feedback(groupID: groupID)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(feedback)
    }

    // MARK: delete

    @MainActor
    static func deleteGroup(_ store: LabStore, groupID: String) throws {
        guard store.group(groupID) != nil else { throw Error.unknownGroup(groupID) }
        store.deleteGroup(groupID)
    }

    @MainActor
    static func deleteClip(_ store: LabStore, clipID: String) throws {
        guard store.clip(clipID) != nil else {
            throw Error.badInput("no Lab clip with id '\(clipID)'")
        }
        store.deleteClip(clipID)
    }
}
