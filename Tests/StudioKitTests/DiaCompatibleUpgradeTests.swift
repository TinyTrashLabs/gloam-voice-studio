import XCTest
import EngineKit
@testable import GVoiceKit
@testable import StudioKit

/// "Make Dia-compatible": a preset pack has no reference clip, so Dia2 cannot
/// speak as it. The upgrade synthesizes one with the preset's OWN engine and
/// files it at `engines/dia2/ref.wav` — Dia2's private reference, deliberately
/// not the pack's top-level one.
final class DiaCompatibleUpgradeTests: XCTestCase {
    var dir: URL!
    var lib: VoiceLibrary!

    /// One Kokoro preset, the shape the seeder writes: a speaker binding and
    /// nothing else.
    private let preset = PresetVoice(slug: "kokoro-af-heart", name: "Heart",
                                     engine: "kokoro", speaker: "af_heart",
                                     notes: "Warm and bright.")

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voices-\(UUID().uuidString)")
        lib = VoiceLibrary(directory: dir)
        PresetVoiceSeeder.seed(into: lib, catalog: [preset], version: 1)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A second of quiet tone — enough to be a real WAV through RefLoudness.
    private func sampleWav() -> Data {
        let samples = (0..<24_000).map { Float(sin(Double($0) * 0.05)) * 0.3 }
        return WAVEncoder.encode(pcm16: PCM16.data(from: samples), sampleRate: 24_000)
    }

    private var dia2RefURL: URL {
        dir.appendingPathComponent(preset.slug)
            .appendingPathComponent("engines/dia2/ref.wav")
    }

    func testPresetPackIsNotDialogueCapableBeforeTheUpgrade() {
        XCTAssertFalse(lib.capabilities(preset.slug).supports(.dia2))
    }

    func testWritingTheDia2ReferenceMakesThePackDialogueCapable() throws {
        try lib.writeEngineAsset(preset.slug, engine: "dia2",
                                 file: "ref.wav", data: sampleWav())
        XCTAssertTrue(lib.capabilities(preset.slug).supports(.dia2))
        XCTAssertEqual(try Dia2Alignment.referenceURL(preset.slug, in: lib)?
            .resolvingSymlinksInPath(), dia2RefURL.resolvingSymlinksInPath())
    }

    /// The whole reason the clip goes under `engines/dia2/` rather than at the
    /// pack root: a synthesized reference is a Dia2 conditioning aid, not a
    /// recording of a person, and must not silently enable every cloning engine.
    func testTheDia2ReferenceDoesNotMakeThePackCloneableElsewhere() throws {
        try lib.writeEngineAsset(preset.slug, engine: "dia2",
                                 file: "ref.wav", data: sampleWav())
        let caps = lib.capabilities(preset.slug)
        XCTAssertFalse(caps.hasSource)
        XCTAssertFalse(caps.supports(.chatterbox))
        XCTAssertFalse(caps.supports(.luxTTS))
        XCTAssertNil(try lib.entry(preset.slug).refURL)
    }

    func testWritingToAnUnknownVoiceThrows() {
        XCTAssertThrowsError(try lib.writeEngineAsset("no-such-voice", engine: "dia2",
                                                      file: "ref.wav", data: sampleWav()))
    }

    // MARK: surviving the seeder

    /// The upgrade must not read as a user edit: a pack that gained a Dia2
    /// reference is still the bundled preset, and still gets catalog refreshes.
    func testTheUpgradedPackIsStillBundled() throws {
        try lib.writeEngineAsset(preset.slug, engine: "dia2",
                                 file: "ref.wav", data: sampleWav())
        XCTAssertTrue(PresetVoiceSeeder.isBundled(try lib.meta(preset.slug), in: lib))
    }

    /// ...and because it is still refreshable, a catalog bump rewrites the pack.
    /// That rewrite must leave the upgrade alone, or the feature silently
    /// un-installs itself on the next app update.
    func testACatalogRefreshKeepsTheDia2Reference() throws {
        try lib.writeEngineAsset(preset.slug, engine: "dia2",
                                 file: "ref.wav", data: sampleWav())
        let renamed = PresetVoice(slug: preset.slug, name: "Heart (US)",
                                  engine: preset.engine, speaker: preset.speaker,
                                  notes: preset.notes)
        let report = PresetVoiceSeeder.seed(into: lib, catalog: [renamed], version: 2)
        XCTAssertEqual(report.refreshed, 1)
        XCTAssertEqual(try lib.meta(preset.slug).name, "Heart (US)")
        XCTAssertTrue(lib.capabilities(preset.slug).supports(.dia2))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dia2RefURL.path))
    }

    /// The one refresh that MUST drop it: the catalog rebound this slug to a
    /// different speaker, so the stored clip is now a different voice than the
    /// pack claims to be. Keeping it would put a stranger in the dialogue.
    func testARebindingRefreshDropsTheStaleDia2Reference() throws {
        try lib.writeEngineAsset(preset.slug, engine: "dia2",
                                 file: "ref.wav", data: sampleWav())
        try Dia2Alignment.store([AlignedWord(w: "hello", start: 0, end: 0.4)],
                                for: preset.slug, in: lib)
        let rebound = PresetVoice(slug: preset.slug, name: preset.name,
                                  engine: preset.engine, speaker: "af_bella",
                                  notes: preset.notes)
        PresetVoiceSeeder.seed(into: lib, catalog: [rebound], version: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dia2RefURL.path))
        XCTAssertNil(Dia2Alignment.cached(preset.slug, in: lib))
        XCTAssertFalse(lib.capabilities(preset.slug).supports(.dia2))
    }
}
