import Foundation

/// A single entry in the downloadable voice catalog.
public struct CatalogVoice: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var language: String
    public var license: String
    public var attribution: String
    public var audioURL: String
    public var refText: String

    public init(
        id: String,
        name: String,
        language: String,
        license: String,
        attribution: String,
        audioURL: String,
        refText: String
    ) {
        self.id = id
        self.name = name
        self.language = language
        self.license = license
        self.attribution = attribution
        self.audioURL = audioURL
        self.refText = refText
    }
}
