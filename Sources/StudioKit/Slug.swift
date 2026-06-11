import Foundation

public enum Slug {
    /// Lowercase, collapse runs of non-[a-z0-9] to a single dash, strip
    /// leading/trailing dashes. Parity with voices.slugify (Python).
    public static func slugify(_ name: String) throws -> String {
        var out = ""
        var lastWasDash = false
        for ch in name.lowercased() {
            if ch.isASCII && (("a"..."z").contains(ch) || ("0"..."9").contains(ch)) {
                out.append(ch)
                lastWasDash = false
            } else if !out.isEmpty && !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        if out.hasSuffix("-") { out.removeLast() }
        guard !out.isEmpty else { throw StudioError.invalidName(name) }
        return out
    }
}
