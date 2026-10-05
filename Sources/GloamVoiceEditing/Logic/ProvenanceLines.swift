import Foundation
import GVoiceKit

/// The pack's `provenance` is opaque JSON the producing tool wrote for
/// itself (Rule 1: preserved verbatim, never interpreted). The editor shows
/// it read-only so a pack from someone else is inspectable; this flattens
/// it to `key.path → value` lines in a stable order.
public enum ProvenanceLines {
    public struct Line: Equatable {
        public let key: String
        public let value: String
        public init(key: String, value: String) { self.key = key; self.value = value }
    }

    public static func flatten(_ value: JSONValue, prefix: String = "") -> [Line] {
        switch value {
        case .object(let o):
            return o.keys.sorted().flatMap { k in
                flatten(o[k]!, prefix: prefix.isEmpty ? k : "\(prefix).\(k)")
            }
        case .array(let a):
            return a.enumerated().flatMap { i, v in flatten(v, prefix: "\(prefix)[\(i)]") }
        case .string(let s): return [Line(key: prefix, value: s)]
        case .number(let n):
            let v = n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
            return [Line(key: prefix, value: v)]
        case .bool(let b): return [Line(key: prefix, value: b ? "yes" : "no")]
        case .null: return [Line(key: prefix, value: "—")]
        }
    }
}
