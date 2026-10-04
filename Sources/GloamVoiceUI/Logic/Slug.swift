import Foundation
import GVoiceKit

/// Verbatim copy of StudioKit's `Slug` (gloam-voice-studio/Sources/StudioKit/
/// Slug.swift). StudioKit cannot link on iOS (it drags in MLX and the HTTP
/// server), and moving this into GVoiceKit would touch a dozen desktop files
/// for fifteen lines. Both apps must mint the same slug for the same name;
/// if this changes, change the desktop copy too.
public enum Slug {
    /// Lowercase, collapse runs of non-[a-z0-9] to a single dash, strip
    /// leading/trailing dashes.
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
