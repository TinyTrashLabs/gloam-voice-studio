import XCTest
@testable import StudioKit

/// Voice identity at the library level: id minted once, revision bumped by audio/character/photo edits,
/// both carried through export and import, and languages riding on takes.
final class VoiceIdentityTests: XCTestCase {
    private var dirs: [URL] = []

    private func library() -> VoiceLibrary {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("identity-\(UUID().uuidString)")
        dirs.append(dir)
        return VoiceLibrary(directory: dir)
    }

    override func tearDown() {
        dirs.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private let wav = Data([0, 1, 2])
    private var png: Data {
        // 1x1 PNG
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
    }

    func testNewVoiceGetsIdAndRevisionOne() throws {
        let lib = library()
        let meta = try lib.save(name: "Cruz", refWav: wav, refText: "hi")
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(meta.id)))
        XCTAssertEqual(meta.revision, 1)
        XCTAssertEqual(try lib.meta("cruz").id, meta.id)
    }

    func testEditsBumpRevisionButIdIsStable() throws {
        let lib = library()
        let id = try XCTUnwrap(try lib.save(name: "Cruz", refWav: wav, refText: "hi").id)
        try lib.setPersona("cruz", persona: Persona(systemPrompt: "You are Cruz."))
        XCTAssertEqual(try lib.meta("cruz").revision, 2)
        try lib.saveAvatar("cruz", pngData: png)
        XCTAssertEqual(try lib.meta("cruz").revision, 3)
        try lib.removeAvatar("cruz")
        XCTAssertEqual(try lib.meta("cruz").revision, 4)
        _ = try lib.update("cruz", refText: "new text")
        XCTAssertEqual(try lib.meta("cruz").revision, 5)
        _ = try lib.update("cruz", notes: "gravelly")
        XCTAssertEqual(try lib.meta("cruz").notes, "gravelly")
        XCTAssertEqual(try lib.meta("cruz").revision, 6)
        // A no-op patch is not an edit.
        _ = try lib.update("cruz", refText: "new text", notes: "gravelly")
        XCTAssertEqual(try lib.meta("cruz").revision, 6)
        // A rename re-slugs and still bumps; the id survives it.
        let renamed = try lib.update("cruz", name: "Cruz Prime")
        XCTAssertEqual(renamed.slug, "cruz-prime")
        XCTAssertEqual(renamed.revision, 7)
        XCTAssertEqual(renamed.id, id)
        // Empty notes clear the field.
        XCTAssertNil(try lib.update("cruz-prime", notes: "").notes)
    }

    func testVoiceWithoutIdGetsOneOnFirstEdit() throws {
        let lib = library()
        _ = try lib.save(name: "Old", refWav: wav, refText: "x")
        var meta = try lib.meta("old")
        meta.id = nil; meta.revision = nil
        try lib.write(meta, to: try lib.folder("old"))
        try lib.setPersona("old", persona: nil)
        let after = try lib.meta("old")
        XCTAssertNotNil(after.id)
        XCTAssertEqual(after.revision, 1)
    }

    func testExportWritesIdAndRevisionAndImportKeepsThem() throws {
        let source = library()
        let made = try source.save(name: "Cruz", refWav: wav, refText: "hi")
        try source.setPersona("cruz", persona: Persona(systemPrompt: "You are Cruz."))   // revision 2
        let pack = try GVoice.export("cruz", from: source)
        let manifest = try GVoice.manifest(of: pack)
        XCTAssertEqual(manifest.id, made.id)
        XCTAssertEqual(manifest.revision, 2)

        let target = library()
        let imported = try GVoice.import(pack, into: target)
        XCTAssertEqual(imported.id, made.id)
        XCTAssertEqual(imported.revision, 2, "the setters import runs must not inflate the revision")
        XCTAssertEqual(imported.persona?.systemPrompt, "You are Cruz.")
    }

    func testImportingAKnownIdKeepsBothWithANewId() throws {
        let lib = library()
        let made = try lib.save(name: "Cruz", refWav: wav, refText: "hi")
        let pack = try GVoice.export("cruz", from: lib)
        // Same name is the same address, which an import never overwrites.
        XCTAssertThrowsError(try lib.importPack(pack)) {
            XCTAssertEqual($0 as? StudioError, .voiceExists(slug: "cruz"))
        }
        // Renamed locally, the pack is a second copy of the same voice: it keeps both, with a new id.
        _ = try lib.update("cruz", name: "Cruz Prime")
        let copy = try lib.importPack(pack)
        XCTAssertEqual(copy.slug, "cruz")
        XCTAssertNotEqual(copy.id, made.id)
        XCTAssertEqual(lib.voice(withID: try XCTUnwrap(made.id))?.slug, "cruz-prime")
        XCTAssertEqual(lib.list().count, 2)
    }

    func testUpdateImportReplacesTheOlderVoiceOnlyWhenNewer() throws {
        let origin = library()
        let made = try origin.save(name: "Cruz", refWav: wav, refText: "hi")
        let v1 = try GVoice.export("cruz", from: origin)
        try origin.setPersona("cruz", persona: Persona(systemPrompt: "v2"))
        let v2 = try GVoice.export("cruz", from: origin)

        let lib = library()
        _ = try lib.importPack(v1)
        let updated = try lib.importPack(v2, update: true)
        XCTAssertEqual(lib.list().count, 1)
        XCTAssertEqual(updated.id, made.id)
        XCTAssertEqual(updated.persona?.systemPrompt, "v2")
        XCTAssertEqual(updated.revision, 2)
        // Without `update`, or with a pack that is not newer, nothing is replaced.
        XCTAssertThrowsError(try lib.importPack(v1, update: true))
        XCTAssertThrowsError(try lib.importPack(v2))
        XCTAssertEqual(try lib.meta("cruz").persona?.systemPrompt, "v2")
    }

    func testLanguageTakeRoundTripsThroughExportImport() throws {
        let lib = library()
        _ = try lib.save(name: "Benson", refWav: wav, refText: "hello there")
        try lib.setLanguage("benson", "en")
        let take = try lib.addLanguageTake("benson", language: "es", refWav: Data([3, 4, 5]),
                                           refText: "hola")
        XCTAssertEqual(take.slug, "benson-es")
        XCTAssertEqual(take.language, "es")
        XCTAssertEqual(take.variantOf, "benson")
        XCTAssertEqual(try lib.meta("benson").revision, 2)
        XCTAssertEqual(lib.languages(of: "benson"), ["en", "es"])

        let pack = try GVoice.export("benson", from: lib)
        let manifest = try GVoice.manifest(of: pack)
        XCTAssertEqual(manifest.language, "en")
        XCTAssertEqual(manifest.source?["es"]?.language, "es")

        let other = library()
        _ = try GVoice.import(pack, into: other)
        XCTAssertEqual(other.languages(of: "benson"), ["en", "es"])
        XCTAssertEqual(try other.meta("benson-es").refText, "hola")
    }

    func testTakeLookupMatchesPrimarySubtagAndSkipsTheVoiceItself() throws {
        let lib = library()
        _ = try lib.save(name: "Benson", refWav: wav, refText: "hello")
        try lib.setLanguage("benson", "en")
        try lib.addLanguageTake("benson", language: "es", refWav: wav, refText: "hola")
        XCTAssertEqual(lib.take(of: "benson", language: "es-MX")?.meta.slug, "benson-es")
        XCTAssertEqual(lib.take(of: "benson", language: "ES")?.meta.slug, "benson-es")
        XCTAssertNil(lib.take(of: "benson", language: "en"), "the voice's own language uses the voice")
        XCTAssertNil(lib.take(of: "benson", language: "fr"))
        XCTAssertNil(lib.take(of: "benson", language: nil))
        XCTAssertNil(lib.take(of: "benson", language: "auto"))
    }

    func testLanguageKeyValidation() {
        XCTAssertEqual(VoiceLibrary.languageKey("es"), "es")
        XCTAssertEqual(VoiceLibrary.languageKey(" en_US "), "en-us")
        XCTAssertNil(VoiceLibrary.languageKey(""))
        XCTAssertNil(VoiceLibrary.languageKey("base"))
        XCTAssertNil(VoiceLibrary.languageKey("../x"))
        XCTAssertNil(VoiceLibrary.languageKey("a b"))
    }

    func testAddLanguageTakeOnUnknownVoiceThrows() {
        XCTAssertThrowsError(try library().addLanguageTake("nope", language: "es", refWav: wav, refText: "x")) {
            XCTAssertEqual($0 as? StudioError, .voiceNotFound(slug: "nope"))
        }
    }
}
