/// A loaded speech model. Conformers are responsible for their own thread-safety
/// (they are `Sendable`); GloamEngine additionally serializes all calls through a
/// task chain, so `synthesize` is never invoked concurrently in practice.
public protocol SpeechModel: AnyObject, Sendable {
    var sampleRate: Int { get }
    func synthesize(_ request: ProviderRequest) async throws -> [Float]
}

/// Loads models. Real implementation wraps mlx-audio-swift; tests use fakes.
public protocol ModelProviding: Sendable {
    func loadModel(backend: BackendID) async throws -> any SpeechModel
    /// Called after a model is dropped, to release accelerator memory.
    func didEvictModel()
}

public extension SpeechModel {
    /// Streaming is opt-in. Engines that generate a whole take at once get a
    /// single-chunk stream, so callers only ever write the streaming path.
    func synthesizeStream(_ request: ProviderRequest) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    continuation.yield(try await synthesize(request))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

public struct DialoguePrefix: Sendable {
    public var samples: [Float]
    public var words: [AlignedWordTiming]
    public init(samples: [Float], words: [AlignedWordTiming]) {
        self.samples = samples; self.words = words
    }
}

/// EngineKit's own timing type, so EngineKit does not depend on StudioKit.
/// StudioKit's `AlignedWord` maps onto it at the call site.
public struct AlignedWordTiming: Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) {
        self.text = text; self.start = start; self.end = end
    }
}

public struct ProviderDialogueRequest: Sendable {
    public var script: [String]
    /// Index 0 is speaker 1, index 1 is speaker 2.
    public var prefixes: [DialoguePrefix?]
    /// Legacy aliases for the audio sampler. Kept so existing clients compile;
    /// new dialogue surfaces should use the explicit audio fields below.
    public var temperature: Float?
    public var topK: Int?
    public var cfgScale: Float?
    public var textTemperature: Float?
    public var textTopK: Int?
    public var audioTemperature: Float?
    public var audioTopK: Int?
    public var maxPadding: Int?
    public var keepPrefixAudio: Bool
    public init(script: [String], prefixes: [DialoguePrefix?],
                temperature: Float? = nil, topK: Int? = nil, cfgScale: Float? = nil,
                textTemperature: Float? = nil, textTopK: Int? = nil,
                audioTemperature: Float? = nil, audioTopK: Int? = nil,
                maxPadding: Int? = nil, keepPrefixAudio: Bool = false) {
        self.script = script; self.prefixes = prefixes
        self.temperature = temperature; self.topK = topK; self.cfgScale = cfgScale
        self.textTemperature = textTemperature; self.textTopK = textTopK
        self.audioTemperature = audioTemperature; self.audioTopK = audioTopK
        self.maxPadding = maxPadding; self.keepPrefixAudio = keepPrefixAudio
    }
}

public struct DialogueChunk: Sendable {
    public let samples: [Float]
    public let words: [AlignedWordTiming]
    public init(samples: [Float], words: [AlignedWordTiming]) {
        self.samples = samples; self.words = words
    }
}

enum DialogueOutputAssembler {
    static func assemble(generated: DialogueChunk, prefixes: [DialoguePrefix?],
                         sampleRate: Int, keepPrefixAudio: Bool) -> DialogueChunk {
        guard keepPrefixAudio, sampleRate > 0 else { return generated }

        var samples: [Float] = []
        var words: [AlignedWordTiming] = []
        var offset = 0.0
        for prefix in prefixes.compactMap({ $0 }) {
            samples.append(contentsOf: prefix.samples)
            words.append(contentsOf: prefix.words.map {
                AlignedWordTiming(text: $0.text,
                                  start: $0.start + offset,
                                  end: $0.end + offset)
            })
            offset += Double(prefix.samples.count) / Double(sampleRate)
        }
        samples.append(contentsOf: generated.samples)
        words.append(contentsOf: generated.words.map {
            AlignedWordTiming(text: $0.text,
                              start: $0.start + offset,
                              end: $0.end + offset)
        })
        return DialogueChunk(samples: samples, words: words)
    }
}

public protocol DialogueStreaming: Sendable {
    func append(_ lines: [String]) async
    func finish() async
    func cancel() async
    var audio: AsyncThrowingStream<DialogueChunk, Error> { get }
}

/// Implemented only by backends that speak two voices in one pass.
public protocol DialogueSpeechModel: SpeechModel {
    var nonverbalTags: [String] { get }
    func synthesizeDialogue(_ request: ProviderDialogueRequest) async throws -> DialogueChunk
    func openDialogueSession(_ request: ProviderDialogueRequest) throws -> any DialogueStreaming
}
