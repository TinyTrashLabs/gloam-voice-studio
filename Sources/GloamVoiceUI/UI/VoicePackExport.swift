import CoreTransferable
import Foundation
import GVoiceKit
import UniformTypeIdentifiers

extension UTType {
    /// Same identifier the desktop app exports (`Documents.swift`), so a pack
    /// AirDropped from the Mac opens here and vice versa.
    public static let gvoice = UTType(exportedAs: "fm.gloam.gvoice", conformingTo: .zip)
}

/// A voice as a shareable `.gvoice`. Exports when the share sheet asks for
/// the file, not when the view is built, so a row's menu costs nothing
/// until it is used.
public struct VoicePackExport: Transferable {
    public let voice: Voice
    public let includeSource: Bool
    private let build: @Sendable () throws -> Data

    /// A store that cannot share this voice (`packExport` is nil) makes an
    /// export whose `write` throws `VoiceEditorUnsupported`.
    @MainActor
    public init(voice: Voice, includeSource: Bool, store: any VoiceLibraryStore) {
        self.voice = voice
        self.includeSource = includeSource
        self.build = store.packExport(for: voice, includeSource: includeSource)
            ?? { throw VoiceEditorUnsupported("share this voice") }
    }

    public static func filename(for voice: Voice) -> String { "\(voice.slug).gvoice" }

    /// Writes `tmp/<slug>.gvoice` and returns it. Throws `StudioError` when
    /// the voice has nothing shareable in the requested form.
    @MainActor
    public func write() throws -> URL {
        let data = try build()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(Self.filename(for: voice))
        try data.write(to: url, options: .atomic)
        return url
    }

    /// The same file, zipped off the main thread. A 30 s master deflates in
    /// hundreds of milliseconds on a phone, which is a visible freeze when it
    /// happens under a tap; `PackShare` runs this and shows the wait instead.
    @MainActor
    public func writeInBackground() async throws -> URL {
        let voice = voice, build = build
        return try await Task.detached(priority: .userInitiated) {
            let data = try build()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(Self.filename(for: voice))
            try data.write(to: url, options: .atomic)
            return url
        }.value
    }

    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .gvoice) { export in
            SentTransferredFile(try await MainActor.run { try export.write() })
        }
        .suggestedFileName { Self.filename(for: $0.voice) }
    }
}
