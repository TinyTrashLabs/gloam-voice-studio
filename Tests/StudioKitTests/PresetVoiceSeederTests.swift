import XCTest
import EngineKit
@testable import StudioKit

final class PresetVoiceSeederTests: XCTestCase {
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

    // MARK: the catalog

    func testCatalogCoversEveryEnginePreset() {
        XCTAssertEqual(PresetVoiceCatalog.supertonic.count, BackendID.supertonicVoices.count)
        XCTAssertEqual(PresetVoiceCatalog.kokoro.count, BackendID.kokoroVoices.count)
        XCTAssertEqual(PresetVoiceCatalog.qwenCustom.count, BackendID.qwenPresetSpeakers.count)
    }

    /// `af_dora`/`ef_dora`/`pf_dora`, the three Santas, both Alexes and both
    /// Alphas share a stem — engine-prefixed slugs and language-qualified names
    /// are what keep them apart.
    func testSlugsAndNamesAreUnique() {
        let slugs = PresetVoiceCatalog.all.map(\.slug)
        XCTAssertEqual(Set(slugs).count, slugs.count)
        let names = PresetVoiceCatalog.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
    }

    /// A preset slug must never look like an emotion variant of another voice.
    func testNoSlugIsAPrefixOfAnother() {
        let slugs = Set(PresetVoiceCatalog.all.map(\.slug))
        for slug in slugs {
            for other in slugs where other != slug {
                XCTAssertFalse(other.hasPrefix("\(slug)-"),
                               "\(other) reads as a variant of \(slug)")
            }
        }
    }

    // MARK: seeding

    func testSeedsEveryPresetAsARenderablePack() {
        let report = PresetVoiceSeeder.seed(into: lib)
        XCTAssertEqual(report.created, PresetVoiceCatalog.all.count)
        XCTAssertEqual(lib.list().count, PresetVoiceCatalog.all.count)

        XCTAssertEqual(lib.rendition("supertonic-m1", engine: "supertonic"),
                       .builtinSpeaker("M1"))
        XCTAssertEqual(lib.rendition("kokoro-af-heart", engine: "kokoro"),
                       .builtinSpeaker("af_heart"))
        XCTAssertEqual(lib.rendition("qwen3-custom-uncle-fu", engine: "qwen3-custom"),
                       .builtinSpeaker("Uncle_Fu"))
    }

    func testSeededPackSupportsOnlyItsOwnEngine() {
        PresetVoiceSeeder.seed(into: lib)
        let caps = lib.capabilities("supertonic-m1")
        XCTAssertTrue(caps.supports(.supertonic))
        XCTAssertFalse(caps.supports(.kokoro))
        XCTAssertFalse(caps.supports(.chatterbox))
        XCTAssertFalse(caps.supports(.luxTTS))
    }

    func testNotesAreSeeded() {
        PresetVoiceSeeder.seed(into: lib)
        XCTAssertEqual(try lib.meta("kokoro-af-heart").notes?.contains("Graded A"), true)
        XCTAssertEqual(try lib.meta("supertonic-f3").notes?.contains("female"), true)
    }

    func testReseedingIsANoOp() {
        PresetVoiceSeeder.seed(into: lib)
        let second = PresetVoiceSeeder.seed(into: lib)
        XCTAssertEqual(second.created, 0)
        XCTAssertEqual(second.refreshed, 0)
        XCTAssertEqual(second.skipped, PresetVoiceCatalog.all.count)
    }

    func testAVersionBumpRefreshesUntouchedPacks() throws {
        PresetVoiceSeeder.seed(into: lib, version: 1)
        let renamedCatalog = [PresetVoice(slug: "supertonic-m1", name: "SuperTonic M1 (v2)",
                                          engine: "supertonic", speaker: "M1", notes: "new")]
        let report = PresetVoiceSeeder.seed(into: lib, catalog: renamedCatalog, version: 2)
        XCTAssertEqual(report.refreshed, 1)
        XCTAssertEqual(try lib.meta("supertonic-m1").name, "SuperTonic M1 (v2)")
    }

    // MARK: the rule that must not break

    func testARenamedPresetIsNeverClobbered() throws {
        PresetVoiceSeeder.seed(into: lib)
        _ = try lib.update("supertonic-m1", name: "Gravel")

        // Both a re-seed at the same version and a catalog version bump.
        PresetVoiceSeeder.seed(into: lib)
        PresetVoiceSeeder.seed(into: lib, version: PresetVoiceCatalog.version + 1)

        XCTAssertEqual(try lib.meta("gravel").name, "Gravel")
        XCTAssertEqual(lib.rendition("gravel", engine: "supertonic"), .builtinSpeaker("M1"))
        // The rename freed the old slug; re-seeding may legitimately refill it,
        // but it must never have reached into the renamed pack.
        XCTAssertNotEqual(try? lib.meta("supertonic-m1").name, "Gravel")
    }

    func testAPresetGivenAPersonaIsUserOwned() throws {
        PresetVoiceSeeder.seed(into: lib, version: 1)
        _ = try lib.setPersona("supertonic-m2", persona: Persona(systemPrompt: "gruff"))

        let bumped = [PresetVoice(slug: "supertonic-m2", name: "Something Else",
                                  engine: "supertonic", speaker: "M2", notes: "new")]
        let report = PresetVoiceSeeder.seed(into: lib, catalog: bumped, version: 2)
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(try lib.meta("supertonic-m2").persona?.systemPrompt, "gruff")
        XCTAssertNotEqual(try lib.meta("supertonic-m2").name, "Something Else")
    }

    func testAPresetGivenAnAvatarIsUserOwned() throws {
        PresetVoiceSeeder.seed(into: lib, version: 1)
        try lib.saveAvatar("supertonic-m3", pngData: Data([1, 2, 3]))

        let bumped = [PresetVoice(slug: "supertonic-m3", name: "Something Else",
                                  engine: "supertonic", speaker: "M3", notes: "new")]
        XCTAssertEqual(PresetVoiceSeeder.seed(into: lib, catalog: bumped, version: 2).skipped, 1)
        XCTAssertNotEqual(try lib.meta("supertonic-m3").name, "Something Else")
    }

    /// The sidebar's Bundled shelf is the seeder's own "may I overwrite this?"
    /// test: untouched presets are bundled, anything a user edited is theirs.
    func testBundledIsUntouchedAndPromotionLeavesIt() throws {
        PresetVoiceSeeder.seed(into: lib)
        XCTAssertTrue(PresetVoiceSeeder.isBundled(try lib.meta("supertonic-m1"), in: lib))
        XCTAssertTrue(PresetVoiceSeeder.isBundled(try lib.meta("kokoro-af-heart"), in: lib))

        _ = try lib.setPersona("supertonic-m1", persona: Persona(systemPrompt: "gruff"))
        XCTAssertFalse(PresetVoiceSeeder.isBundled(try lib.meta("supertonic-m1"), in: lib))

        _ = try lib.update("kokoro-af-heart", name: "Heart of Gold")
        XCTAssertFalse(PresetVoiceSeeder.isBundled(try lib.meta("heart-of-gold"), in: lib))

        let mine = try lib.save(name: "Mine", refWav: Data([1]), refText: "hello")
        XCTAssertFalse(PresetVoiceSeeder.isBundled(mine, in: lib))
    }

    func testAUsersOwnVoiceAtAPresetSlugIsNeverTouched() throws {
        _ = try lib.saveAt(slug: "supertonic-m1", name: "Mine", refWav: Data([1]),
                           refText: "hello")
        let report = PresetVoiceSeeder.seed(into: lib)
        XCTAssertEqual(try lib.meta("supertonic-m1").name, "Mine")
        XCTAssertEqual(report.created, PresetVoiceCatalog.all.count - 1)
    }
}
