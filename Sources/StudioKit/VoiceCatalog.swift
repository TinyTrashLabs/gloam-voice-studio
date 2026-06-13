import Foundation

/// A single audio clip in a voice pack.
public struct CatalogClip: Codable, Sendable, Equatable {
    public var emotion: String?          // nil = base voice; else variant suffix (excited, warm, …)
    public var audioURL: String?         // remote mp3 source
    public var bundledResource: String?  // filename of a wav bundled in the app (e.g. "ava.wav")
    public var refText: String           // "" means: transcribe on install

    public init(emotion: String?, audioURL: String?, bundledResource: String?, refText: String) {
        self.emotion = emotion
        self.audioURL = audioURL
        self.bundledResource = bundledResource
        self.refText = refText
    }
}

/// A voice pack in the downloadable voice catalog.
public struct CatalogVoice: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var language: String
    public var license: String
    public var attribution: String
    public var clips: [CatalogClip]

    /// The base voice clip (emotion == nil).
    public var baseClip: CatalogClip? { clips.first { $0.emotion == nil } }

    /// Emotion variant suffixes available in this pack.
    public var emotions: [String] { clips.compactMap { $0.emotion } }

    public init(
        id: String,
        name: String,
        language: String,
        license: String,
        attribution: String,
        clips: [CatalogClip]
    ) {
        self.id = id
        self.name = name
        self.language = language
        self.license = license
        self.attribution = attribution
        self.clips = clips
    }
}
