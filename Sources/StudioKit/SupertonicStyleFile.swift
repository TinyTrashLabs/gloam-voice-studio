import Foundation

/// Validation errors for an imported/baked SuperTonic style JSON.
public enum SupertonicStyleError: Error, Equatable {
    case notJSON
    /// Wrong/missing dims, missing data, or value count mismatch.
    case badShape(String)
    case nonFinite
    /// A style row's L2 norm is not ~1.0 (SuperTonic styles live on a product of unit spheres).
    case notUnitRows
}

/// Validates the on-disk SuperTonic style descriptor — the
/// `{ "style_ttl": {dims,data}, "style_dp": {dims,data} }` schema that the
/// SuperTonic model parses (a per-voice `supertonic.json`). Used to gate imports
/// (a Voice Builder export or a shared style) and to sanity-check baked output.
/// Unknown top-level keys (e.g. Voice Builder's `metadata`) are tolerated.
public enum SupertonicStyleFile {
    /// Expected tensor dims.
    public static let ttlDims = [1, 50, 256]
    public static let dpDims = [1, 8, 16]
    /// Per-row L2 tolerance around 1.0 (baked/exported styles are unit-row).
    static let unitRowTolerance = 0.05

    public static func validate(_ data: Data) throws {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SupertonicStyleError.notJSON
        }
        try validateTensor(obj["style_ttl"], dims: ttlDims, name: "style_ttl")
        try validateTensor(obj["style_dp"], dims: dpDims, name: "style_dp")
    }

    private static func validateTensor(_ any: Any?, dims expected: [Int], name: String) throws {
        guard let t = any as? [String: Any] else {
            throw SupertonicStyleError.badShape("\(name): missing")
        }
        guard let dims = (t["dims"] as? [NSNumber])?.map(\.intValue), dims == expected else {
            throw SupertonicStyleError.badShape("\(name): dims != \(expected)")
        }
        guard let values = flatten(t["data"]) else {
            throw SupertonicStyleError.badShape("\(name): missing/invalid data")
        }
        let count = expected.reduce(1, *)
        guard values.count == count else {
            throw SupertonicStyleError.badShape("\(name): \(values.count) values != \(count)")
        }
        guard values.allSatisfy({ $0.isFinite }) else { throw SupertonicStyleError.nonFinite }

        let rowLen = expected.last!
        let rows = count / rowLen
        for r in 0..<rows {
            var sumSq = 0.0
            for i in 0..<rowLen { let v = values[r * rowLen + i]; sumSq += v * v }
            guard abs(sumSq.squareRoot() - 1.0) <= unitRowTolerance else {
                throw SupertonicStyleError.notUnitRows
            }
        }
    }

    /// Depth-first flatten of the tensor `data` (stored as flat or nested arrays) to `[Double]`.
    private static func flatten(_ any: Any?) -> [Double]? {
        var out: [Double] = []
        func walk(_ x: Any?) -> Bool {
            if let n = x as? NSNumber { out.append(n.doubleValue); return true }
            if let arr = x as? [Any] {
                for e in arr where !walk(e) { return false }
                return true
            }
            return false
        }
        return walk(any) ? out : nil
    }
}
