import XCTest
import EngineKit
@testable import StudioKit

/// `rendition(_:engine:)` — how a pack says it renders on one engine, and the
/// promotable contract that a pack need not carry reference audio at all.
final class VoiceRenditionTests: XCTestCase {
    var dir: URL!
    var lib: VoiceLibrary!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voices-\(UUID().uuidString)")
        lib = VoiceLibrary(directory: dir)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func json(_ object: [String: String]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: shapes

    func testVoiceJSONSpeakerIsABuiltinSpeaker() throws {
        _ = try lib.save(name: "Heart", refWav: nil, refText: "",
                         engines: ["kokoro": ["voice.json": json(["speaker": "af_heart"])]])
        XCTAssertEqual(lib.rendition("heart", engine: "kokoro"), .builtinSpeaker("af_heart"))
    }

    func testStyleFileIsAStyle() throws {
        _ = try lib.save(name: "Billie", refWav: nil, refText: "",
                         engines: ["supertonic": ["style.json": Data([1])]])
        guard case .style(let url)? = lib.rendition("billie", engine: "supertonic") else {
            return XCTFail("expected a style rendition")
        }
        XCTAssertEqual(url.lastPathComponent, "style.json")
    }

    /// A speaker beats a style file: naming the engine's own preset is the
    /// explicit statement, and a promoted preset may carry both.
    func testSpeakerWinsOverStyleFile() throws {
        _ = try lib.save(name: "Both", refWav: nil, refText: "",
                         engines: ["supertonic": ["voice.json": json(["speaker": "M1"]),
                                                  "style.json": Data([1])]])
        XCTAssertEqual(lib.rendition("both", engine: "supertonic"), .builtinSpeaker("M1"))
    }

    /// lux-tts stores its reference window in voice.json, qwen3-design an
    /// instruct, elevenlabs a voiceId. None is a speaker and none is a style.
    func testVoiceJSONWithoutASpeakerIsNotARendition() throws {
        _ = try lib.save(name: "Lux", refWav: nil, refText: "",
                         engines: ["lux-tts": ["voice.json": json(["text": "hello"])]])
        XCTAssertNil(lib.rendition("lux", engine: "lux-tts"))
    }

    func testBlankSpeakerIsNotARendition() throws {
        _ = try lib.save(name: "Blank", refWav: nil, refText: "",
                         engines: ["kokoro": ["voice.json": json(["speaker": "  "])]])
        XCTAssertNil(lib.rendition("blank", engine: "kokoro"))
    }

    func testUnknownEngineHasNoRendition() throws {
        _ = try lib.save(name: "Billie", refWav: nil, refText: "",
                         engines: ["supertonic": ["style.json": Data([1])]])
        XCTAssertNil(lib.rendition("billie", engine: "kokoro"))
    }

    // MARK: the latent bug this replaced

    /// `renditionStyleURL` used to return the first .json in the engine dir,
    /// so a kokoro pointer came back as a *style URL*. The planner then saw
    /// styleURL != nil, zeroed the speaker, and Kokoro was handed `voice: nil`.
    func testKokoroPointerIsNotAStyleURL() throws {
        _ = try lib.save(name: "Heart", refWav: nil, refText: "",
                         engines: ["kokoro": ["voice.json": json(["speaker": "af_heart"])]])
        XCTAssertNil(lib.renditionStyleURL("heart", engine: "kokoro"))
    }

    func testRenditionStyleURLStillFindsRealStyles() throws {
        _ = try lib.save(name: "Billie", refWav: nil, refText: "",
                         engines: ["supertonic": ["style.json": Data([1])]])
        XCTAssertNotNil(lib.renditionStyleURL("billie", engine: "supertonic"))
    }

    // MARK: variant → base fallback

    func testVariantFallsBackToItsBase() throws {
        _ = try lib.save(name: "Cruz", refWav: nil, refText: "",
                         engines: ["supertonic": ["voice.json": json(["speaker": "M2"])]])
        _ = try lib.saveAt(slug: "cruz-hype", name: "Cruz Hype", refWav: nil,
                           refText: "", variantOf: "cruz")
        XCTAssertEqual(lib.rendition("cruz-hype", engine: "supertonic"), .builtinSpeaker("M2"))
    }

    func testVariantsOwnRenditionWins() throws {
        _ = try lib.save(name: "Cruz", refWav: nil, refText: "",
                         engines: ["supertonic": ["voice.json": json(["speaker": "M2"])]])
        _ = try lib.saveAt(slug: "cruz-hype", name: "Cruz Hype", refWav: nil, refText: "",
                           variantOf: "cruz",
                           engines: ["supertonic": ["voice.json": json(["speaker": "M4"])]])
        XCTAssertEqual(lib.rendition("cruz-hype", engine: "supertonic"), .builtinSpeaker("M4"))
    }

    // MARK: capabilities

    func testNameBoundPackSupportsOnlyItsOwnEngine() throws {
        _ = try lib.save(name: "M1", refWav: nil, refText: "",
                         engines: ["supertonic": ["voice.json": json(["speaker": "M1"])]])
        let caps = lib.capabilities("m1")
        XCTAssertTrue(caps.supports(.supertonic))
        XCTAssertFalse(caps.supports(.chatterbox))
        XCTAssertFalse(caps.supports(.kokoro))
    }

    // MARK: the promotable contract

    /// A preset pack has no ref.wav. If identity edits went through `get()`,
    /// which requires one, a preset could never be renamed or given a persona
    /// — so it could never be promoted into a full voice.
    func testMetadataEditsWorkWithoutReferenceAudio() throws {
        _ = try lib.save(name: "M1", refWav: nil, refText: "",
                         engines: ["supertonic": ["voice.json": json(["speaker": "M1"])]],
                         notes: "A fixed preset style.")
        XCTAssertEqual(try lib.meta("m1").notes, "A fixed preset style.")

        let renamed = try lib.update("m1", name: "Gravel")
        XCTAssertEqual(renamed.name, "Gravel")
        XCTAssertEqual(renamed.slug, "gravel")
        // The rename must not change what it renders as: the binding lives in
        // engines/<id>/voice.json, not in the slug or the display name.
        XCTAssertEqual(lib.rendition("gravel", engine: "supertonic"), .builtinSpeaker("M1"))

        _ = try lib.setPersona("gravel", persona: Persona(systemPrompt: "gruff"))
        XCTAssertEqual(try lib.meta("gravel").persona?.systemPrompt, "gruff")

        _ = try lib.setGain("gravel", gainDb: -2)
        XCTAssertEqual(lib.gainDb(for: "gravel"), -2)
    }

    func testNotesRoundTripThroughMeta() throws {
        _ = try lib.save(name: "Cruz", refWav: Data([1]), refText: "t", notes: "warm")
        XCTAssertEqual(try lib.meta("cruz").notes, "warm")
    }
}

/// Export of the name-bound preset packs.
extension VoiceRenditionTests {
    /// The strip exists so a cloned pack cannot claim a likeness on an engine
    /// that only speaks its own voices. A pack with no source of its own is the
    /// opposite case: the pointer IS the voice, and stripping it left an empty
    /// pack that would not import.
    func testAPresetPackExportsItsPointer() throws {
        _ = try lib.save(name: "Heart", refWav: nil, refText: "",
                         engines: ["kokoro": ["voice.json": json(["speaker": "af_heart"])]],
                         notes: "American English female.")
        let data = try GVoice.export("heart", from: lib)

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("voices-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dest) }
        let other = VoiceLibrary(directory: dest)
        _ = try GVoice.import(data, into: other)
        XCTAssertEqual(other.rendition("heart", engine: "kokoro"), .builtinSpeaker("af_heart"))
    }

    /// Unchanged for the case the strip was written for.
    func testAClonedPackStillStripsItsKokoroPointer() throws {
        _ = try lib.save(name: "Benson", refWav: Data([1]), refText: "hello",
                         engines: ["kokoro": ["voice.json": json(["speaker": "af_heart"])]])
        let data = try GVoice.export("benson", from: lib)

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("voices-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dest) }
        let other = VoiceLibrary(directory: dest)
        _ = try GVoice.import(data, into: other)
        XCTAssertNil(other.rendition("benson", engine: "kokoro"))
    }
}
