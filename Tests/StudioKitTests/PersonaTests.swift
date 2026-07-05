import XCTest
@testable import StudioKit

final class PersonaTests: XCTestCase {
    var dir: URL!
    var library: VoiceLibrary!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("persona-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        library = VoiceLibrary(directory: dir)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testLegacyMetaWithoutPersonaDecodes() throws {
        let legacy = #"{"name":"Old Voice","slug":"old-voice","refText":"hi","createdAt":"2026-01-01T00:00:00Z"}"#
        let meta = try JSONDecoder().decode(VoiceMeta.self, from: Data(legacy.utf8))
        XCTAssertNil(meta.persona)
        XCTAssertEqual(meta.name, "Old Voice")
    }

    func testNilPersonaIsOmittedOnDisk() throws {
        let meta = VoiceMeta(name: "V", slug: "v", refText: "r", createdAt: "2026-01-01T00:00:00Z")
        let json = String(decoding: try JSONEncoder().encode(meta), as: UTF8.self)
        XCTAssertFalse(json.contains("persona"), "nil persona must not appear in meta.json")
    }

    func testSetPersonaPersistsAndClears() throws {
        _ = try library.save(name: "Chatty", refWav: Data([0]), refText: "ref line")
        let persona = Persona(systemPrompt: "You are a pirate.", greeting: "Ahoy!")
        let updated = try library.setPersona("chatty", persona: persona)
        XCTAssertEqual(updated.persona, persona)
        let reloaded = try library.get("chatty").meta
        XCTAssertEqual(reloaded.persona?.systemPrompt, "You are a pirate.")
        XCTAssertEqual(reloaded.persona?.greeting, "Ahoy!")

        let cleared = try library.setPersona("chatty", persona: nil)
        XCTAssertNil(cleared.persona)
        XCTAssertNil(try library.get("chatty").meta.persona)
    }

    func testCorruptPersonaFieldIsTolerated() throws {
        let bad = #"{"name":"V","slug":"v","refText":"r","createdAt":"x","persona":"not-an-object"}"#
        let meta = try JSONDecoder().decode(VoiceMeta.self, from: Data(bad.utf8))
        XCTAssertNil(meta.persona, "malformed persona must not break voice load")
    }
}
