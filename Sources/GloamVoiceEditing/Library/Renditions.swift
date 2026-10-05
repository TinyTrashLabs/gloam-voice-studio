import Foundation

/// What a pack carries per engine, as rows a screen can list: the files and
/// their sizes, and the pace overrides other engines carry (the voice's own
/// pace is the `lux-tts` override, which a Pace control shows itself).
public enum Renditions {
    /// Engine id → (file name, size) rows, engines sorted.
    public static func rows(engines: [String: [String: URL]]) -> [(engine: String, files: [(name: String, bytes: Int)])] {
        engines.keys.sorted().map { engine in
            let files = (engines[engine] ?? [:]).keys.sorted().map { name -> (String, Int) in
                let bytes = (try? FileManager.default.attributesOfItem(atPath: engines[engine]![name]!.path)[.size] as? Int) ?? 0
                return (name, bytes)
            }
            return (engine, files)
        }
    }

    /// The overrides worth listing beside the Pace slider: every engine's
    /// but `lux-tts`, whose override the slider itself shows.
    public static func paceOverrides(_ enginePace: [String: Double]?) -> [(engine: String, pace: Double)] {
        (enginePace ?? [:]).filter { $0.key != "lux-tts" && $0.value > 0 }
            .keys.sorted().map { ($0, enginePace![$0]!) }
    }

    public static func sizeLabel(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
