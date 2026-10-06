import EngineKit
import Foundation

/// How a voice reads in a list row: a short title and an optional subtitle in
/// words. Never the slug — "kokoro-am-adam" is a storage key, not a description.
///
/// Preset names carry their qualifier after a middle dot ("Adam · American
/// English"); in a narrow sidebar that pushed the part that tells two Alexes
/// apart into the truncation. Splitting it onto the subtitle line, next to the
/// engine that speaks it, keeps both readable.
public struct VoiceRowLabel: Equatable, Sendable {
    public var title: String
    public var subtitle: String?

    public init(title: String, subtitle: String?) {
        self.title = title
        self.subtitle = subtitle
    }

    public init(_ meta: VoiceMeta) {
        let parts = meta.name.components(separatedBy: " · ")
        let title = parts[0].trimmingCharacters(in: .whitespaces)
        let rest = parts.dropFirst().joined(separator: " · ").trimmingCharacters(in: .whitespaces)
        let qualifier: String? = rest.isEmpty ? nil : rest
        let engine = Self.presetEngine(meta)

        let subtitle: String?
        if let engine {
            if let qualifier {
                let q = qualifier.lowercased()
                if q == engine.familyName.lowercased() || q == engine.displayName.lowercased() {
                    subtitle = engine.displayName            // "Aiden · Qwen" → "Qwen Custom"
                } else if q.contains(engine.familyName.lowercased()) {
                    subtitle = qualifier                     // already names its engine
                } else {
                    subtitle = "\(engine.displayName) · \(qualifier)"
                }
            } else {
                subtitle = engine.displayName
            }
        } else {
            subtitle = qualifier
                ?? Self.nonEmpty(meta.persona?.tagline)
                ?? Self.firstSentence(meta.notes)
        }
        self.init(title: title.isEmpty ? meta.name : title, subtitle: subtitle)
    }

    /// The engine a built-in preset voice belongs to, from its provenance mark.
    static func presetEngine(_ meta: VoiceMeta) -> BackendID? {
        guard case .object(let provenance)? = meta.provenance,
              case .object(let mark)? = provenance["preset"],
              case .string(let engine)? = mark["engine"] else { return nil }
        return BackendID(rawValue: engine)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private static func firstSentence(_ s: String?) -> String? {
        guard let t = nonEmpty(s) else { return nil }
        let line = t.split(whereSeparator: \.isNewline).first.map(String.init) ?? t
        if let end = line.range(of: ". ") { return String(line[..<end.lowerBound]) }
        return line
    }
}
