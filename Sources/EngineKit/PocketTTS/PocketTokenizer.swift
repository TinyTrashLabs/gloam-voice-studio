// PocketTokenizer.swift
//
// Minimal SentencePiece **unigram** tokenizer for Pocket TTS's
// `tokenizer.model` (4000 pieces), used by the direct-ONNX Pocket engine.
//
// Why hand-rolled: swift-transformers' `Tokenizers` loads Hugging Face
// `tokenizer.json` configs, not raw SentencePiece protobufs, and pulling in a
// SentencePiece C++ dependency for one 4000-entry vocab is not worth it. This
// model makes a faithful port small: its normalizer is `identity` (no
// precompiled charsmap, no NFKC), `add_dummy_prefix` and `escape_whitespaces`
// are on, `remove_extra_whitespaces` is off, and `byte_fallback` is on — so
// encoding is: prepend one space, map ' ' → '▁' (U+2581), then Viterbi over
// the piece lattice with unknown characters falling back to `<0xNN>` byte
// pieces. Verified token-for-token against Python `sentencepiece` on the
// bench sentences (see PocketTokenizerTests).
//
// The protobuf is parsed by hand (pieces + normalizer flags only); a model
// with a non-identity normalizer is rejected loudly rather than tokenized
// wrongly.

import Foundation

public final class PocketTokenizer {
    public enum TokenizerError: Error, LocalizedError {
        case unreadable(String)
        case malformedProto(String)
        case unsupported(String)
        public var errorDescription: String? {
            switch self {
            case .unreadable(let m): return "tokenizer.model unreadable: \(m)"
            case .malformedProto(let m): return "tokenizer.model malformed: \(m)"
            case .unsupported(let m): return "tokenizer.model unsupported: \(m)"
            }
        }
    }

    // SentencePiece piece types (sentencepiece_model.proto). NORMAL is the
    // proto2 default and is usually omitted on the wire.
    private enum PieceType: Int { case normal = 1, unknown = 2, control = 3, userDefined = 4, unused = 5, byte = 6 }

    public let vocabSize: Int
    private let pieces: [String]         // id → piece text
    private let scores: [Float]
    private let addDummyPrefix: Bool
    private let removeExtraWhitespaces: Bool
    private let unkID: Int
    private let unkScore: Float
    private let byteID: [Int]            // byte value → id of "<0xNN>", or -1

    // Byte-trie over matchable pieces. Flat arrays instead of node objects:
    // built once, walked per character position during Viterbi.
    private let trieChildren: [[UInt8: Int32]]
    private let trieTerminal: [Int32]  // piece id ending at this node, or -1

    public init(modelPath: URL) throws {
        guard let data = try? Data(contentsOf: modelPath) else {
            throw TokenizerError.unreadable(modelPath.path)
        }
        var parsedPieces: [(piece: String, score: Float, type: PieceType)] = []
        var dummyPrefix = true, removeExtra = true, escapeWS = true
        var charsmapBytes = 0

        // ModelProto: field 1 = repeated SentencePiece, field 3 = NormalizerSpec.
        var reader = ProtoReader(data)
        while let (field, wire) = try reader.tag() {
            switch (field, wire) {
            case (1, .lengthDelimited):
                var p = ProtoReader(try reader.bytes())
                var piece = ""; var score: Float = 0; var type = PieceType.normal
                while let (f, w) = try p.tag() {
                    switch (f, w) {
                    case (1, .lengthDelimited):
                        piece = String(decoding: try p.bytes(), as: UTF8.self)
                    case (2, .fixed32):
                        score = Float(bitPattern: try p.fixed32())
                    case (3, .varint):
                        type = PieceType(rawValue: Int(try p.varint())) ?? .normal
                    default: try p.skip(w)
                    }
                }
                parsedPieces.append((piece, score, type))
            case (3, .lengthDelimited):
                var n = ProtoReader(try reader.bytes())
                while let (f, w) = try n.tag() {
                    switch (f, w) {
                    case (2, .lengthDelimited): charsmapBytes = try n.bytes().count
                    case (3, .varint): dummyPrefix = try n.varint() != 0
                    case (4, .varint): removeExtra = try n.varint() != 0
                    case (5, .varint): escapeWS = try n.varint() != 0
                    default: try n.skip(w)
                    }
                }
            default:
                try reader.skip(wire)
            }
        }

        guard !parsedPieces.isEmpty else { throw TokenizerError.malformedProto("no pieces") }
        // A precompiled charsmap means real normalization rules (NFKC etc.)
        // this port does not implement — refuse rather than mis-tokenize.
        guard charsmapBytes == 0 else {
            throw TokenizerError.unsupported("non-identity normalizer (charsmap present)")
        }
        guard escapeWS else { throw TokenizerError.unsupported("escape_whitespaces=false") }

        vocabSize = parsedPieces.count
        pieces = parsedPieces.map(\.piece)
        scores = parsedPieces.map(\.score)
        addDummyPrefix = dummyPrefix
        removeExtraWhitespaces = removeExtra

        var unk = 0
        var bytes = [Int](repeating: -1, count: 256)
        var minScore = Float.greatestFiniteMagnitude
        var children: [[UInt8: Int32]] = [[:]]
        var terminal: [Int32] = [-1]
        func insert(pieceBytes: [UInt8], id: Int32) {
            var node = 0
            for b in pieceBytes {
                if let next = children[node][b] {
                    node = Int(next)
                } else {
                    children.append([:])
                    terminal.append(-1)
                    let next = Int32(children.count - 1)
                    children[node][b] = next
                    node = Int(next)
                }
            }
            terminal[node] = id
        }
        for (id, p) in parsedPieces.enumerated() {
            switch p.type {
            case .unknown: unk = id
            case .byte:
                // "<0xNN>"
                if p.piece.count == 6, p.piece.hasPrefix("<0x"), p.piece.hasSuffix(">"),
                   let v = UInt8(p.piece.dropFirst(3).dropLast(), radix: 16) {
                    bytes[Int(v)] = id
                }
            case .normal, .userDefined:
                minScore = min(minScore, p.score)
                insert(pieceBytes: Array(p.piece.utf8), id: Int32(id))
            case .control, .unused:
                break
            }
        }
        unkID = unk
        // sentencepiece's kUnkPenalty: an unknown character scores 10 below
        // the worst real piece so it is only used when nothing else covers.
        unkScore = minScore - 10
        byteID = bytes
        trieChildren = children
        trieTerminal = terminal
    }

    /// SentencePiece `encode(text, out_type=int)` — no BOS/EOS added.
    public func encode(_ text: String) -> [Int] {
        var t = text
        if removeExtraWhitespaces {
            while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
            t = t.trimmingCharacters(in: CharacterSet(charactersIn: " "))
        }
        if addDummyPrefix { t = " " + t }
        t = t.replacingOccurrences(of: " ", with: "\u{2581}")

        let bytes = Array(t.utf8)
        let n = bytes.count
        guard n > 0 else { return [] }

        // UTF-8 character boundary structure for the lattice.
        var isCharStart = [Bool](repeating: false, count: n + 1)
        for i in 0..<n where (bytes[i] & 0xC0) != 0x80 { isCharStart[i] = true }
        isCharStart[n] = true
        func nextBoundary(after i: Int) -> Int {
            var j = i + 1
            while j <= n, !isCharStart[j] { j += 1 }
            return j
        }

        // Viterbi: dpPiece[j] = piece id of the best edge ending at j
        // (-2 = unknown-character edge), dpPrev[j] = where it started.
        var dpScore = [Float](repeating: -.greatestFiniteMagnitude, count: n + 1)
        var dpPrev = [Int](repeating: -1, count: n + 1)
        var dpPiece = [Int32](repeating: -1, count: n + 1)
        dpScore[0] = 0

        var i = 0
        while i < n {
            defer { i = nextBoundary(after: i) }
            guard isCharStart[i], dpScore[i] > -.greatestFiniteMagnitude else { continue }
            let charEnd = nextBoundary(after: i)
            var coveredSingleChar = false
            var node = 0
            var j = i
            while j < n, let next = trieChildren[node][bytes[j]] {
                node = Int(next)
                j += 1
                let pid = trieTerminal[node]
                if pid >= 0 {
                    if j == charEnd { coveredSingleChar = true }
                    let s = dpScore[i] + scores[Int(pid)]
                    if s > dpScore[j] { dpScore[j] = s; dpPrev[j] = i; dpPiece[j] = pid }
                }
            }
            if !coveredSingleChar {
                let s = dpScore[i] + unkScore
                if s > dpScore[charEnd] {
                    dpScore[charEnd] = s; dpPrev[charEnd] = i; dpPiece[charEnd] = -2
                }
            }
        }

        var out: [Int] = []
        var pos = n
        while pos > 0 {
            let start = dpPrev[pos]
            if dpPiece[pos] == -2 {
                // Unknown character: byte fallback (this model has the full
                // <0x00>..<0xFF> table), else the <unk> id.
                var ids: [Int] = []
                for b in bytes[start..<pos] { ids.append(byteID[Int(b)] >= 0 ? byteID[Int(b)] : unkID) }
                out.append(contentsOf: ids.reversed())
            } else {
                out.append(Int(dpPiece[pos]))
            }
            pos = start
        }
        return out.reversed()
    }

    /// SentencePiece `decode`: join pieces, '▁' → ' ', drop the leading space,
    /// reassemble byte-fallback pieces into UTF-8. Used for sentence chunking.
    public func decode(_ ids: [Int]) -> String {
        var buf: [UInt8] = []
        for id in ids {
            guard id >= 0, id < vocabSize else { continue }
            let piece = pieces[id]
            if piece.count == 6, piece.hasPrefix("<0x"), piece.hasSuffix(">"),
               let v = UInt8(piece.dropFirst(3).dropLast(), radix: 16) {
                buf.append(v)
            } else if piece.hasPrefix("<"), piece.hasSuffix(">"), id == unkID || piece == "<s>" || piece == "</s>" || piece == "<pad>" {
                continue  // control tokens render as nothing
            } else {
                buf.append(contentsOf: Array(piece.utf8))
            }
        }
        var s = String(decoding: buf, as: UTF8.self)
            .replacingOccurrences(of: "\u{2581}", with: " ")
        if s.hasPrefix(" ") { s.removeFirst() }
        return s
    }
}

// MARK: - Tiny protobuf wire reader

/// Just enough proto2 wire-format reading for sentencepiece_model.proto.
private struct ProtoReader {
    enum Wire: UInt64 { case varint = 0, fixed64 = 1, lengthDelimited = 2, fixed32 = 5 }
    private let data: [UInt8]
    private var pos = 0

    init(_ d: Data) { data = [UInt8](d) }
    init(_ d: [UInt8]) { data = d }

    /// Next (fieldNumber, wireType), or nil at end of buffer.
    mutating func tag() throws -> (Int, Wire)? {
        guard pos < data.count else { return nil }
        let key = try varint()
        guard let wire = Wire(rawValue: key & 7) else {
            throw PocketTokenizer.TokenizerError.malformedProto("wire type \(key & 7)")
        }
        return (Int(key >> 3), wire)
    }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard pos < data.count, shift < 64 else {
                throw PocketTokenizer.TokenizerError.malformedProto("truncated varint")
            }
            let b = data[pos]; pos += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
        }
    }

    mutating func fixed32() throws -> UInt32 {
        guard pos + 4 <= data.count else {
            throw PocketTokenizer.TokenizerError.malformedProto("truncated fixed32")
        }
        defer { pos += 4 }
        return UInt32(data[pos]) | UInt32(data[pos + 1]) << 8
            | UInt32(data[pos + 2]) << 16 | UInt32(data[pos + 3]) << 24
    }

    mutating func bytes() throws -> [UInt8] {
        let len = Int(try varint())
        guard pos + len <= data.count else {
            throw PocketTokenizer.TokenizerError.malformedProto("truncated bytes")
        }
        defer { pos += len }
        return Array(data[pos ..< pos + len])
    }

    mutating func skip(_ wire: Wire) throws {
        switch wire {
        case .varint: _ = try varint()
        case .fixed64:
            guard pos + 8 <= data.count else {
                throw PocketTokenizer.TokenizerError.malformedProto("truncated fixed64")
            }
            pos += 8
        case .lengthDelimited: _ = try bytes()
        case .fixed32: _ = try fixed32()
        }
    }
}
