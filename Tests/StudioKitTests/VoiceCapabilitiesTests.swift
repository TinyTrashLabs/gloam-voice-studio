import XCTest
import EngineKit
@testable import StudioKit

final class VoiceCapabilitiesTests: XCTestCase {
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

    // MARK: derivation

    func testSourceOnlyVoice() throws {
        _ = try lib.save(name: "Cruz", refWav: Data([1]), refText: "hello")
        let caps = lib.capabilities("cruz")
        XCTAssertTrue(caps.hasSource)
        XCTAssertTrue(caps.hasRefText)
        XCTAssertTrue(caps.engines.isEmpty)
    }

    func testRenditionOnlyVoice() throws {
        _ = try lib.save(name: "Billie", refWav: nil, refText: "",
                         engines: ["supertonic": ["style.json": Data([1])]])
        let caps = lib.capabilities("billie")
        XCTAssertFalse(caps.hasSource)
        XCTAssertFalse(caps.hasRefText)
        XCTAssertEqual(caps.engines, ["supertonic"])
    }

    func testSourceAndRenditionVoice() throws {
        _ = try lib.save(name: "Billie Frost", refWav: Data([1]), refText: "t",
                         engines: ["supertonic": ["style.json": Data([1])],
                                   "lux-tts": ["ref.wav": Data([2]), "voice.json": Data([3])]])
        let caps = lib.capabilities("billie-frost")
        XCTAssertTrue(caps.hasSource)
        XCTAssertEqual(caps.engines, ["supertonic", "lux-tts"])
    }

    func testEmptyEngineDirIgnored() throws {
        _ = try lib.save(name: "Cruz", refWav: Data([1]), refText: "")
        let empty = dir.appendingPathComponent("cruz/engines/supertonic")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertTrue(lib.capabilities("cruz").engines.isEmpty)
    }

    func testUnknownVoiceIsEmpty() {
        let caps = lib.capabilities("nope")
        XCTAssertFalse(caps.hasSource)
        XCTAssertTrue(caps.engines.isEmpty)
    }

    // MARK: rendition style lookup

    func testRenditionStyleURLFindsJson() throws {
        _ = try lib.save(name: "Billie", refWav: nil, refText: "",
                         engines: ["supertonic": ["style.json": Data([1])]])
        XCTAssertEqual(lib.renditionStyleURL("billie", engine: "supertonic")?.lastPathComponent,
                       "style.json")
        XCTAssertNil(lib.renditionStyleURL("billie", engine: "lux-tts"))
    }

    func testVariantFallsBackToBaseRendition() throws {
        _ = try lib.save(name: "Billie", refWav: Data([1]), refText: "t",
                         engines: ["supertonic": ["style.json": Data([1])]])
        try lib.saveAt(slug: "billie-warm", name: "Billie warm", refWav: Data([2]),
                       refText: "t", variantOf: "billie")
        XCTAssertEqual(lib.renditionStyleURL("billie-warm", engine: "supertonic")?.path,
                       lib.renditionStyleURL("billie", engine: "supertonic")?.path)
    }

    func testVariantOwnRenditionWins() throws {
        _ = try lib.save(name: "Billie", refWav: Data([1]), refText: "t",
                         engines: ["supertonic": ["style.json": Data([1])]])
        try lib.saveAt(slug: "billie-warm", name: "Billie warm", refWav: nil,
                       refText: "", variantOf: "billie",
                       engines: ["supertonic": ["style.json": Data([2])]])
        XCTAssertTrue(lib.renditionStyleURL("billie-warm", engine: "supertonic")!.path
            .contains("billie-warm/"))
    }

    // MARK: supports

    private func caps(source: Bool = false, refText: Bool = false,
                      engines: Set<String> = []) -> VoiceCapabilities {
        VoiceCapabilities(hasSource: source, hasRefText: refText, engines: engines)
    }

    func testCloningBackendNeedsSource() {
        XCTAssertTrue(caps(source: true).supports(.chatterbox))
        XCTAssertFalse(caps().supports(.chatterbox))
    }

    func testRefTextConditionedBackendNeedsTranscriptToo() {
        // qwen base + lux clone from audio AND transcript.
        XCTAssertFalse(caps(source: true).supports(.qwen17B))
        XCTAssertTrue(caps(source: true, refText: true).supports(.qwen17B))
        XCTAssertFalse(caps(source: true).supports(.luxTTS))
        // chatterbox/fish clone from audio alone.
        XCTAssertTrue(caps(source: true).supports(.fishS2Pro))
    }

    func testRenditionEnablesNonCloningBackend() {
        XCTAssertTrue(caps(engines: ["supertonic"]).supports(.supertonic))
        XCTAssertFalse(caps(source: true, refText: true).supports(.supertonic))
        XCTAssertFalse(caps(engines: ["supertonic"]).supports(.kokoro))
    }

    func testRenditionEnablesCloningBackendWithoutSource() {
        // A rendition-only pack (includeSource: false export) still renders on
        // the engine it was baked for, even a cloning one.
        XCTAssertTrue(caps(engines: ["lux-tts"]).supports(.luxTTS))
    }

    func testDesignBackendNeverEnabledByLibraryVoice() {
        XCTAssertFalse(caps(source: true, refText: true).supports(.qwenDesign))
        XCTAssertFalse(caps(engines: ["qwen3-design"]).supports(.qwenDesign))
    }

    func testUnknownEngineIdNeverMatches() {
        XCTAssertFalse(caps(engines: ["some-future-engine"]).supports(.supertonic))
    }
}
