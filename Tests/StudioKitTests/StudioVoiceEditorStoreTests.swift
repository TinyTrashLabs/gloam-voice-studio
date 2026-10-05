import XCTest
import GloamVoiceEditing
import GVoiceKit
@testable import StudioKit

/// The Studio library through the shared editor's store protocol. Language
/// references are first-class: tagged takes, listed as languages, never as
/// emotion versions.
@MainActor
final class StudioVoiceEditorStoreTests: XCTestCase {
    var dir: URL!
    var lib: VoiceLibrary!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("editor-store-\(UUID().uuidString)")
        lib = VoiceLibrary(directory: dir)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }
    }

    private func wav(seconds: Double = 4) -> Data {
        ReferenceSection.wavData((0 ..< Int(seconds * 24_000)).map { i in
            0.3 * Float(sin(2 * .pi * 180 * Double(i) / 24_000))
        }, sampleRate: 24_000)
    }

    func testLanguagesAreReferencesNotEmotionVersions() throws {
        _ = try lib.save(name: "Cruz", refWav: wav(), refText: "Hello there, friend.")
        _ = try lib.saveAt(slug: "cruz-hype", name: "Cruz hype", refWav: wav(), refText: "Let's go!", variantOf: "cruz")
        let store = StudioVoiceEditorStore(library: lib)
        XCTAssertTrue(store.features.contains(.languages))

        try store.addLanguageReference("cruz", language: "es", wav: wav(), transcript: "Hola, amigo.")
        let refs = store.languageReferences(of: "cruz")
        XCTAssertEqual(refs.map(\.language), ["es"])
        XCTAssertEqual(refs.first?.text, "Hola, amigo.")
        XCTAssertNotNil(refs.first?.url)
        XCTAssertEqual(store.voices.map(\.slug), ["cruz"])
        XCTAssertEqual(store.voices.first?.variantKeys, ["hype"], "the language take is not an emotion version")
        XCTAssertTrue(store.languages(of: "cruz").contains("es"))

        let revision = try lib.meta("cruz").revision ?? 0
        try store.removeLanguageReference("cruz", language: "es")
        XCTAssertEqual(store.languageReferences(of: "cruz"), [])
        XCTAssertEqual(try lib.meta("cruz").revision, revision + 1, "removing a language is a new version of the pack")
        XCTAssertEqual(store.voices.first?.variantKeys, ["hype"])
    }

    func testCoreEdits() throws {
        _ = try lib.save(name: "Cruz", refWav: wav(), refText: "Hello there, friend.")
        let store = StudioVoiceEditorStore(library: lib)
        let voice = try XCTUnwrap(store.voices.first)
        XCTAssertEqual(store.referenceText(of: "cruz"), "Hello there, friend.")
        XCTAssertEqual(store.referenceURL(of: "cruz"), store.masterURL(of: "cruz"))
        try store.update("cruz") { $0.notes = "gravelly" }
        XCTAssertEqual(store.voices.first?.meta.notes, "gravelly")
        try store.updateTranscript(of: voice, "Hello there.")
        XCTAssertEqual(store.referenceText(of: "cruz"), "Hello there.")
        XCTAssertThrowsError(try store.updateTranscript(of: voice, "  "))
        let pack = try XCTUnwrap(store.packExport(for: voice, includeSource: true))()
        XCTAssertFalse(pack.isEmpty)
    }
}
