import Foundation

/// Turning HTML fragments into the plain text a language model should read.
///
/// Deliberately small and dependency-free: everything here operates on a
/// string, so it is trivially testable and cannot drag WebKit into targets
/// that only want to parse a search result.
public enum HTMLText {
    /// Strip tags, decode entities, and collapse whitespace.
    public static func plain(_ html: String) -> String {
        var out = ""
        var inTag = false
        for character in html {
            switch character {
            case "<": inTag = true
            case ">": inTag = false
            default: if !inTag { out.append(character) }
            }
        }
        return collapsingWhitespace(decodingEntities(out))
    }

    public static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The named entities that actually turn up in titles and snippets, plus
    /// numeric ones. Not a complete HTML5 entity table on purpose — the full
    /// list is 2,000 entries to fix a handful of characters nobody writes
    /// headlines with.
    public static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[rest.startIndex..<amp]
            rest = rest[rest.index(after: amp)...]
            guard let semi = rest.firstIndex(of: ";"),
                  rest.distance(from: rest.startIndex, to: semi) <= 8
            else {
                out.append("&")
                continue
            }
            let name = String(rest[rest.startIndex..<semi])
            rest = rest[rest.index(after: semi)...]
            out += replacement(for: name) ?? "&\(name);"
        }
        return out + rest
    }

    private static func replacement(for name: String) -> String? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos", "#39": return "'"
        case "nbsp": return " "
        case "hellip": return "…"
        case "mdash": return "—"
        case "ndash": return "–"
        case "rsquo", "#8217": return "\u{2019}"
        case "lsquo": return "\u{2018}"
        case "ldquo": return "\u{201C}"
        case "rdquo": return "\u{201D}"
        default: break
        }
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let value: UInt32?
        if digits.hasPrefix("x") || digits.hasPrefix("X") {
            value = UInt32(digits.dropFirst(), radix: 16)
        } else {
            value = UInt32(digits)
        }
        return value.flatMap(UnicodeScalar.init).map { String(Character($0)) }
    }
}
