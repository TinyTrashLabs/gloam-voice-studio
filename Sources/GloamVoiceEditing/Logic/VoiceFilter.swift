import Foundation

/// Search matching shared by the Voices tab and the Compose voice picker, so
/// the two never drift on what counts as a hit.
public enum VoiceFilter {
    /// Case- and diacritic-insensitive substring match on name, tag, blurb.
    /// Empty/whitespace query matches everything.
    public static func matches(_ v: Voice, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        let haystacks = [v.name, v.tag, v.blurb]
        return haystacks.contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// Clones (!isStarter) first, then starters; stable within each group.
    public static func apply(_ voices: [Voice], query: String) -> [Voice] {
        let matched = voices.filter { matches($0, query: query) }
        let clones = matched.filter { !$0.isStarter }
        let starters = matched.filter { $0.isStarter }
        return clones + starters
    }
}
