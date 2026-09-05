import Foundation

/// The bracketed sounds a model actually knows, read from its tokenizer.
///
/// Every engine here has its own tag vocabulary AND its own bracket style, and
/// they are not interchangeable. Fish and the Qwen family take free-form
/// `[square bracket]` directions; Dia2 takes exactly fifty `(parenthesised)`
/// tokens that exist in its tokenizer and nothing else. A tag the model does
/// not know is not ignored — it is READ ALOUD, so offering the wrong list is
/// worse than offering none.
///
/// Read off disk rather than asked of a loaded model: the chips have to be
/// right before anything is resident, and loading a 2B checkpoint to populate
/// a row of buttons is not a trade worth making.
public enum NonverbalTagCatalog {
    /// Tags declared in a HuggingFace `added_tokens.json`, in the model
    /// directory. Empty when the file is missing or declares none — callers
    /// fall back to their own list rather than showing an empty picker.
    public static func parenthesised(inModelDirectory dir: URL) -> [String] {
        let url = dir.appendingPathComponent("added_tokens.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return object.keys
            .filter { $0.hasPrefix("(") && $0.hasSuffix(")") && $0.count > 2 }
            .filter { !$0.contains(" ") }   // see `usableInAScript` below
            .sorted()
    }

    /// Why a tag containing a space is left out of the list above.
    ///
    /// Dia2's script parser splits each line on whitespace and encodes word by
    /// word, so a two-word tag is torn in half before the tokenizer ever sees
    /// it. Verified against the reference implementation's own tokenizer:
    ///
    ///     "(clears throat)" -> [49156]                    one token
    ///     "(clears"         -> [24, 1668, 954]  ( cle ars
    ///     "throat)"         -> [373, 8331, 25]  th roat )
    ///
    /// The tag is genuinely in the vocabulary — it is the SPLIT that breaks it,
    /// and the reference (`parse_script`, `segment.split()`) splits the same
    /// way, so this is not a porting mistake to fix on our side alone. Those
    /// six subword pieces are ordinary text, which Dia2 reads out loud: offering
    /// "(clears throat)" as a chip is offering to have "clears throat" spoken.
    ///
    /// Fixing it properly means matching added tokens BEFORE splitting, in the
    /// parser, in the vendored fork. Until then these are excluded rather than
    /// offered, because a chip that cannot work is worse than one that is
    /// missing.
    public static func usableInAScript(_ tag: String) -> Bool { !tag.contains(" ") }
}
