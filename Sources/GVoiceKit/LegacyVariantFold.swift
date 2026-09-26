import Foundation

/// Folds a library written in the old sibling layout (`nova/`, `nova-excited/`)
/// into pack folders (`nova/variants/excited/`).
///
/// A take used to be a sibling folder tied to its voice only by
/// `meta.variantOf`, and takes made before that field existed — or by a path
/// that forgot to set it — carry nothing at all. So membership is decided by
/// what the takes DO carry: `variantOf`, or a name built from the voice's name.
/// Deliberately narrow: "Jo Smith" beside "Jo" must stay a voice, so the bare
/// "<name> <word>" / "<name>-<word>" forms only count for a known take word.
///
/// Never deletes. A take whose destination already exists is left where it
/// is and logged. Idempotent: a folded library plans nothing.
public enum LegacyVariantFold {
    /// Studio's `Emotion` and `VoiceExpression` cases plus the radio's
    /// chill/hyped. `VoiceExpression` lives in the app target, so the words
    /// are listed here and pinned by a test.
    public static let takeWords: Set<String> = [
        "flat", "neutral", "warm", "excited", "hype",
        "delight", "angry", "sad", "surprised", "shocked",
        "whisper", "shouting", "screaming", "laughing", "chuckle", "sigh",
        "panting", "moaning", "singing",
        "chill", "hyped",
    ]

    public struct Move: Equatable, Sendable {
        public let folder: String
        public let base: String
        public let key: String
    }

    /// The take key when folder `slug` (with `meta`) is a take of voice `base`
    /// (with `baseMeta`), else nil. `slug` must be `"<base>-<key>"`.
    public static func key(forFolder slug: String, meta: VoiceMeta,
                           baseMeta: VoiceMeta?, base: String) -> String? {
        guard let baseMeta, slug.hasPrefix("\(base)-") else { return nil }
        let key = String(slug.dropFirst(base.count + 1))
        guard !key.isEmpty, (try? GVoice.safeComponent(key)) != nil else { return nil }
        if meta.variantOf == base { return key }
        let name = meta.name.lowercased().trimmingCharacters(in: .whitespaces)
        let baseName = baseMeta.name.lowercased().trimmingCharacters(in: .whitespaces)
        guard !baseName.isEmpty, name.hasPrefix(baseName) else { return nil }
        let rest = name.dropFirst(baseName.count).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("("), rest.hasSuffix(")"), rest.count > 2 { return key }
        if takeWords.contains(rest) { return key }
        // "<Base>-<word>": how RecordEmotionVariantSheet used to name a take.
        if rest.hasPrefix("-"), takeWords.contains(String(rest.dropFirst())) { return key }
        return nil
    }

    private static func readMeta(_ folder: URL) -> VoiceMeta? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")) else { return nil }
        return try? JSONDecoder().decode(VoiceMeta.self, from: data)
    }

    /// What `run` would move, without touching disk.
    public static func plan(in layout: PackFolderLayout) -> [Move] {
        let slugs = layout.voiceSlugs()
        let present = Set(slugs)
        var moves: [Move] = []
        for slug in slugs {
            guard let meta = readMeta(layout.voiceDir(slug)) else { continue }
            // variantOf naming an existing voice decides it outright.
            if let base = meta.variantOf, base != slug, present.contains(base),
               let key = key(forFolder: slug, meta: meta,
                             baseMeta: readMeta(layout.voiceDir(base)), base: base) {
                moves.append(Move(folder: slug, base: base, key: key))
                continue
            }
            // Otherwise the longest base that exists and matches, rightmost split first.
            var cut = slug.endIndex
            while let dash = slug[..<cut].lastIndex(of: "-") {
                let base = String(slug[..<dash])
                if present.contains(base),
                   let key = key(forFolder: slug, meta: meta,
                                 baseMeta: readMeta(layout.voiceDir(base)), base: base) {
                    moves.append(Move(folder: slug, base: base, key: key))
                    break
                }
                cut = dash
            }
        }
        return moves
    }

    /// Fold the library. Copies it to `backup` first (once — an existing backup
    /// is kept) when there is anything to move. Returns what actually moved.
    @discardableResult
    public static func run(in layout: PackFolderLayout, backup: URL?,
                           log: (String) -> Void) throws -> [Move] {
        let moves = plan(in: layout)
        guard !moves.isEmpty else { return [] }
        let fm = FileManager.default
        if let backup, !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: layout.directory, to: backup)
            log("voice library backed up to \(backup.path)")
        }
        var done: [Move] = []
        for move in moves {
            let dest = layout.variantDir(base: move.base, key: move.key)
            guard !fm.fileExists(atPath: dest.path) else {
                log("kept \(move.folder): \(move.base) already has take \(move.key)")
                continue
            }
            try fm.createDirectory(at: layout.variantsDir(move.base), withIntermediateDirectories: true)
            try fm.moveItem(at: layout.voiceDir(move.folder), to: dest)
            if var meta = readMeta(dest) {
                meta.variantOf = move.base
                meta.slug = "\(move.base)-\(move.key)"
                try JSONEncoder().encode(meta).write(to: dest.appendingPathComponent("meta.json"))
            }
            log("folded \(move.folder) into \(move.base) as take \(move.key)")
            done.append(move)
        }
        return done
    }
}
