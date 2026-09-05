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
            .sorted()
    }
}
