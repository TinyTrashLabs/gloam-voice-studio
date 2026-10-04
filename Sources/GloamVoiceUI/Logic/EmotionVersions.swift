import Foundation

/// One emotion a voice can be recorded in: the key the variant slug and the
/// pack carry, what the person reads, and the delivery note over the recorder.
/// The editor takes the list from `VoiceLibraryStore.emotionOptions`, because
/// the Studio app and the radio app do not offer the same set.
public struct EmotionOption: Identifiable, Hashable, Sendable {
    public let key: String
    public let label: String
    /// Shown above the line being read ("Read warmly and gently…").
    public let deliveryNote: String

    public var id: String { key }

    public init(key: String, label: String? = nil, deliveryNote: String) {
        self.key = key
        self.label = label ?? key.capitalized
        self.deliveryNote = deliveryNote
    }

    /// The desktop's list, in its order: what Studio offers.
    public static let studio: [EmotionOption] = [
        .init(key: "flat", deliveryNote: "Read in a flat monotone — minimal inflection, almost bored."),
        .init(key: "neutral", deliveryNote: "Read naturally, like you're explaining something to a friend."),
        .init(key: "warm", deliveryNote: "Read warmly and gently, like comforting someone."),
        .init(key: "excited", deliveryNote: "Read with real energy — like sharing good news."),
        .init(key: "hype", deliveryNote: "Read at maximum energy — like hyping up a crowd."),
    ]
}

/// Fixed script + guidance for recording acted emotion versions. Verbatim
/// from the desktop's `RecordingScript` (StudioKit, which cannot link on
/// iOS) so a pack's variants read the same passage whichever app made them:
/// keeping the words identical isolates delivery as the one variable
/// between recordings -- only the delivery note changes.
public enum EmotionScript {
    public static let passage = """
        The old lighthouse keeper climbed the spiral stairs every evening, \
        counting each of the two hundred steps out loud. From the top, the \
        harbor lights blinked back at him like a code only sailors could \
        read. Some nights the fog rolled in so thick he couldn't see the \
        water at all, just the sound of waves against rock, patient and \
        unhurried, the way they'd been for a hundred years before he was \
        born and would be for a hundred after he was gone.
        """

    public static let tips = [
        "Record somewhere quiet — no fans, traffic, or echoey rooms.",
        "Keep a consistent distance from the mic, about a hand's width away.",
        "Speak at a natural pace — rushing flattens the performance.",
    ]

    /// The note for a Studio emotion key; empty for a key it does not know.
    public static func deliveryNote(for key: String) -> String {
        EmotionOption.studio.first { $0.key == key }?.deliveryNote ?? ""
    }
}

/// How an emotion version is named and which are still to record.
public enum EmotionVersions {
    /// `<base>-<key>`, the sibling directory the library and the format
    /// both expect (`variantOf` says the membership; the name only helps).
    public static func slug(base: String, key: String) -> String { "\(base)-\(key)" }

    /// "Benson hype", the way a pack import names a variant.
    public static func name(base: String, key: String) -> String { "\(base) \(key)" }

    /// Emotions the voice does not have a version of yet.
    public static func available(existingKeys: [String],
                                 options: [EmotionOption] = EmotionOption.studio) -> [EmotionOption] {
        let taken = Set(existingKeys)
        return options.filter { !taken.contains($0.key) }
    }
}
