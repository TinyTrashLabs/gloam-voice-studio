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

public enum DialoguePlanner {
    /// Groups consecutive lines into scenes of at most two distinct voices.
    /// A third voice starts a new scene rather than being dropped, so a
    /// three-person script renders as several exchanges instead of losing one.
    public static func scenes(for lines: [(index: Int, voiceSlug: String?)]) -> [DialogueScene] {
        var scenes: [DialogueScene] = []
        var voices: [String] = []
        var current: [Int] = []

        func flush() {
            guard !current.isEmpty else { return }
            scenes.append(DialogueScene(voices: voices, lines: current))
            voices = []; current = []
        }

        for line in lines {
            if let slug = line.voiceSlug, !voices.contains(slug) {
                if voices.count == 2 { flush() }
                voices.append(slug)
            }
            current.append(line.index)
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
    public init(sceneCount: Int, splitAfterLines: [Int]) {
        self.sceneCount = sceneCount; self.splitAfterLines = splitAfterLines
    }
}

public extension DialoguePlanner {
    static func report(for lines: [(index: Int, voiceSlug: String?)]) -> SceneReport {
        let all = scenes(for: lines)
        let splits = all.dropLast().compactMap(\.lines.last)
        return SceneReport(sceneCount: all.count, splitAfterLines: Array(splits))
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
