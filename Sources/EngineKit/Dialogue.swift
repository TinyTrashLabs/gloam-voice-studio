import Foundation

public struct DialogueTurn: Sendable, Equatable, Codable {
    /// 1 or 2. Dia2 has exactly two speaker tokens.
    public var speaker: Int
    public var text: String
    public init(speaker: Int, text: String) {
        self.speaker = speaker; self.text = text
    }
}

public struct DialogueRequest: Sendable, Equatable {
    public var turns: [DialogueTurn]
    /// Voice slug per speaker index; nil means unconditioned (voice will vary).
    public var voices: [String?]
    /// Legacy aliases for the audio sampler, kept so callers written before the
    /// text/audio split still compile. `audioTemperature`/`audioTopK` win when
    /// both are set, because they say which sampler they mean.
    public var temperature: Float?
    public var topK: Int?
    public var cfgScale: Float?
    /// Dia2 runs two samplers: one over the text/action state machine that
    /// decides what is said and when a speaker changes, one over the audio
    /// codebooks. They want different settings, so the request carries both.
    public var textTemperature: Float?
    public var textTopK: Int?
    public var audioTemperature: Float?
    public var audioTopK: Int?
    public var maxPadding: Int?
    /// Return the conditioning audio ahead of the take. Useful for hearing
    /// exactly what the model was given; wrong for anything shipped.
    public var keepPrefixAudio: Bool

    public init(turns: [DialogueTurn], voices: [String?],
                temperature: Float? = nil, topK: Int? = nil, cfgScale: Float? = nil,
                textTemperature: Float? = nil, textTopK: Int? = nil,
                audioTemperature: Float? = nil, audioTopK: Int? = nil,
                maxPadding: Int? = nil, keepPrefixAudio: Bool = false) {
        self.turns = turns; self.voices = voices
        self.temperature = temperature; self.topK = topK; self.cfgScale = cfgScale
        self.textTemperature = textTemperature; self.textTopK = textTopK
        self.audioTemperature = audioTemperature; self.audioTopK = audioTopK
        self.maxPadding = maxPadding; self.keepPrefixAudio = keepPrefixAudio
    }
}

public extension ProviderDialogueRequest {
    /// Carries every control from the caller's request to the model. Written
    /// once, here, so the HTTP route and the Studio UI cannot drift apart on
    /// which knobs actually reach Dia2 — that drift is why the controls were
    /// silently inert before.
    init(_ dialogue: DialogueRequest, script: [String], prefixes: [DialoguePrefix?]) {
        self.init(script: script, prefixes: prefixes,
                  temperature: dialogue.temperature,
                  topK: dialogue.topK,
                  cfgScale: dialogue.cfgScale,
                  textTemperature: dialogue.textTemperature,
                  textTopK: dialogue.textTopK,
                  audioTemperature: dialogue.audioTemperature,
                  audioTopK: dialogue.audioTopK,
                  maxPadding: dialogue.maxPadding,
                  keepPrefixAudio: dialogue.keepPrefixAudio)
    }
}

public enum DialogueError: Error, LocalizedError, Equatable {
    case tooManySpeakers([String])
    case unknownTag(String)
    case emptyScript

    public var errorDescription: String? {
        switch self {
        case .tooManySpeakers(let names):
            "Dia2 speaks two voices at a time. This scene has \(names.count): "
                + names.joined(separator: ", ") + "."
        case .unknownTag(let tag):
            "\(tag) isn't a sound this model knows, so it would be read aloud. "
                + "Pick a tag from the list, or remove the brackets."
        case .emptyScript:
            "Nothing to say — write a line first."
        }
    }
}

/// A run of script lines that one Dia2 pass can render: at most two voices.
public struct DialogueScene: Sendable, Equatable {
    public var voices: [String]
    public var lines: [Int]
    public init(voices: [String], lines: [Int]) {
        self.voices = voices; self.lines = lines
    }
}

/// One line of script, as the planner sees it: who says it, and what.
public struct DialogueLine: Sendable, Equatable {
    /// Position in the caller's own list, so a split can be reported as a line.
    public var index: Int
    public var voiceSlug: String?
    public var text: String
    /// Who is speaking, for seam placement. Defaults to the voice slug, which
    /// is right whenever voices are assigned; the Dialogue composer passes
    /// "S1"/"S2" so an unvoiced two-hander still has turns to break at.
    public var speakerID: String

    public init(index: Int, voiceSlug: String?, text: String, speakerID: String? = nil) {
        self.index = index; self.voiceSlug = voiceSlug; self.text = text
        self.speakerID = speakerID ?? voiceSlug ?? ""
    }
}

public enum DialoguePlanner {
    /// Measured across clean Dia2 2B renders. Close enough to plan with: the
    /// budget below has enough headroom to absorb a slow or fast reader.
    public static let wordsPerSecond = 2.7

    /// How much audio one Dia2 pass may plan for. Dia2 2B has three ceilings
    /// and only the first is the context window:
    ///
    /// - **~118s** is hard. `max_context_steps` is 1500 and Mimi runs at
    ///   12.5 Hz, so a pass stops after ~1482 generated frames. (The limit
    ///   covers generation only — prefix frames are extra and cost nothing
    ///   against it.)
    /// - **~95-100s** is where a single long pass was seen to break: the two
    ///   speakers' identities merged (measured speaker-similarity margin fell
    ///   to 0.000) and the model repeated lines it had already said. OBSERVED
    ///   ONCE, on one 118s render. Not established as a general threshold.
    /// - **~45s** is where similarity to the reference left its plateau in
    ///   that same render (0.81 over 0-45s, 0.76 at 45-75s, 0.68 at 75-90s,
    ///   0.48 at 105-120s).
    ///
    /// UNVERIFIED: both figures were measured before two changes that affect
    /// them directly -- the prefix scheduler fix (prefix words were being
    /// dropped from the text stream, so conditioning was weaker than it should
    /// have been) and the discovery that the takes were running at a
    /// compressed pace. 45 is therefore a conservative placeholder, not a
    /// derived value, and it wants re-measuring before it is trusted.
    ///
    /// The reasoning behind budgeting at all still holds: generating to 118s
    /// technically succeeds, and splitting costs a seam, because each pass
    /// re-conditions from the original reference audio.
    public static let sceneBudgetSeconds = 45.0

    /// A turn's duration, estimated from its word count. An estimate is enough:
    /// the alternative is generating the take to find out how long it is.
    public static func estimatedSeconds(of text: String) -> Double {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return Double(words.count) / wordsPerSecond
    }

    /// Groups consecutive lines into scenes one Dia2 pass can carry: at most
    /// two distinct voices, and at most `budgetSeconds` of estimated audio.
    ///
    /// A third voice starts a new scene rather than being dropped, so a
    /// three-person script renders as several exchanges instead of losing one.
    ///
    /// The duration split only ever lands where the speaker changes. Every
    /// split is an audible seam, and a seam between two speakers reads as an
    /// ordinary cut where one inside a single speaker's turn reads as damage.
    /// One speaker holding the floor past the budget therefore runs long
    /// on purpose — `SceneReport.overBudgetScenes` is how the UI says so.
    public static func scenes(for lines: [DialogueLine],
                              budgetSeconds: Double = sceneBudgetSeconds) -> [DialogueScene] {
        var scenes: [DialogueScene] = []
        var voices: [String] = []
        var current: [Int] = []
        var seconds = 0.0
        var previousSpeaker: String?

        func flush() {
            guard !current.isEmpty else { return }
            scenes.append(DialogueScene(voices: voices, lines: current))
            voices = []; current = []; seconds = 0
        }

        for line in lines {
            let duration = estimatedSeconds(of: line.text)
            let needsASlot = line.voiceSlug.map { !voices.contains($0) } ?? false
            let speakerChanged = previousSpeaker.map { $0 != line.speakerID } ?? false

            if needsASlot, voices.count == 2 {
                flush()
            } else if speakerChanged, !current.isEmpty, seconds + duration > budgetSeconds {
                flush()
            }
            if let slug = line.voiceSlug, !voices.contains(slug) { voices.append(slug) }
            current.append(line.index)
            seconds += duration
            previousSpeaker = line.speakerID
        }
        flush()
        return scenes
    }

    private static let tagPattern = try! NSRegularExpression(pattern: #"\([a-z][a-z ]*\)"#)

    /// Renders a request as Dia2's tagged script, rejecting anything the model
    /// would mishandle rather than letting it degrade quietly.
    public static func script(for request: DialogueRequest,
                              knownTags: Set<String>) throws -> [String] {
        guard !request.turns.isEmpty,
              request.turns.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
        else { throw DialogueError.emptyScript }

        let speakers = Set(request.turns.map(\.speaker))
        guard speakers.allSatisfy({ $0 == 1 || $0 == 2 }) else {
            throw DialogueError.tooManySpeakers(speakers.sorted().map { "speaker \($0)" })
        }

        if !knownTags.isEmpty {
            for turn in request.turns {
                let ns = turn.text as NSString
                for match in tagPattern.matches(in: turn.text,
                                                range: NSRange(location: 0, length: ns.length)) {
                    let tag = ns.substring(with: match.range)
                    guard knownTags.contains(tag) else { throw DialogueError.unknownTag(tag) }
                }
            }
        }

        return request.turns.map { "[S\($0.speaker)] \($0.text)" }
    }
}

/// How a script divides into Dia2 passes, so the UI can say so before generating.
public struct SceneReport: Sendable, Equatable {
    public let sceneCount: Int
    /// Line indices after which a new scene begins, for the UI to point at.
    public let splitAfterLines: [Int]
    /// Estimated audio per pass, in order.
    public let sceneSeconds: [Double]
    /// Scene indices that could not be split down to the budget — a single
    /// speaker talking past it. They will still render; they will drift.
    public let overBudgetScenes: [Int]

    /// The whole script's estimated duration.
    public var estimatedSeconds: Double { sceneSeconds.reduce(0, +) }

    public init(sceneCount: Int, splitAfterLines: [Int],
                sceneSeconds: [Double] = [], overBudgetScenes: [Int] = []) {
        self.sceneCount = sceneCount; self.splitAfterLines = splitAfterLines
        self.sceneSeconds = sceneSeconds; self.overBudgetScenes = overBudgetScenes
    }
}

public extension DialoguePlanner {
    static func report(for lines: [DialogueLine],
                       budgetSeconds: Double = sceneBudgetSeconds) -> SceneReport {
        let all = scenes(for: lines, budgetSeconds: budgetSeconds)
        let texts = Dictionary(lines.map { ($0.index, $0.text) }, uniquingKeysWith: { a, _ in a })
        let seconds = all.map { scene in
            scene.lines.reduce(0.0) { $0 + estimatedSeconds(of: texts[$1] ?? "") }
        }
        return SceneReport(
            sceneCount: all.count,
            splitAfterLines: Array(all.dropLast().compactMap(\.lines.last)),
            sceneSeconds: seconds,
            overBudgetScenes: seconds.indices.filter { seconds[$0] > budgetSeconds })
    }
}

/// Caps a conditioning clip so the 2-minute context keeps room for the reply.
/// Trimming takes the tail, because a reply should follow the most recent
/// speech, and rebases the timings so the model does not wait out the offset.
public enum ChatPrefixBudget {
    public static func trim(_ words: [AlignedWordTiming], samples: [Float],
                            sampleRate: Int, maxSeconds: Double) -> DialoguePrefix {
        let duration = Double(samples.count) / Double(sampleRate)
        guard duration > maxSeconds, sampleRate > 0 else {
            return DialoguePrefix(samples: samples, words: words)
        }
        let rawCutoff = duration - maxSeconds
        // A prefix is a paired audio/timing grid. Cutting PCM in the middle of
        // the first retained word while rebasing that word to zero makes the
        // two disagree, which weakens conditioning and can create a rough
        // handoff. Prefer the next complete word boundary when timings exist.
        let cutoff = words.first(where: { $0.start >= rawCutoff })?.start ?? rawCutoff
        let firstSample = Int(cutoff * Double(sampleRate))
        let kept = Array(samples[min(firstSample, samples.count)...])
        let rebased = words
            .filter { $0.start >= cutoff }
            .map { AlignedWordTiming(text: $0.text,
                                     start: max(0, $0.start - cutoff),
                                     end: max(0, $0.end - cutoff)) }
        return DialoguePrefix(samples: kept, words: rebased)
    }
}
