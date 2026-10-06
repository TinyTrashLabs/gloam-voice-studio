import XCTest
@testable import StudioKit

/// The Edit Voice takes grid: languages × styles from a voice's takes, read from the fields, with the
/// key only as a hint for packs written before `style` existed.
final class VoiceTakeGridTests: XCTestCase {
    private var dirs: [URL] = []

    private func library() -> VoiceLibrary {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("take-grid-\(UUID().uuidString)")
        dirs.append(dir)
        return VoiceLibrary(directory: dir)
    }

    override func tearDown() {
        dirs.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func meta(_ slug: String, language: String? = nil, style: VoiceStyle? = nil,
                      provenance: JSONValue? = nil) -> VoiceMeta {
        var m = VoiceMeta(name: slug, slug: slug, refText: "words of \(slug)", createdAt: "",
                          provenance: provenance, language: language)
        m.style = style
        return m
    }

    private func names(_ grid: VoiceTakeGrid) -> [String] { grid.columns.map(\.title) }

    func testHomeRowFirstThenOtherLanguagesAndGloamColumnsInOrder() {
        let grid = VoiceTakeGrid(base: meta("benson", language: "en"), variants: [
            ("es", meta("benson-es", language: "es")),
            ("fr", meta("benson-fr", language: "fr")),
            ("excited", meta("benson-excited", style: VoiceStyle.gloam["excited"])),
            ("es-hype", meta("benson-es-hype", language: "es", style: VoiceStyle.gloam["hype"])),
        ])
        XCTAssertEqual(grid.rows.map(\.language), ["en", "es", "fr"])
        XCTAssertEqual(grid.rows.map(\.isHome), [true, false, false])
        XCTAssertEqual(names(grid), ["Natural", "Flat", "Neutral", "Warm", "Excited", "Hype"])
        let en = grid.rows[0], es = grid.rows[1]
        XCTAssertEqual(grid.takes(en, .natural).map(\.key), ["base"])
        XCTAssertTrue(grid.takes(en, .natural)[0].isDefault)
        XCTAssertEqual(grid.takes(es, .natural).map(\.key), ["es"])
        XCTAssertEqual(grid.takes(en, .gloam("excited")).map(\.key), ["excited"])
        XCTAssertEqual(grid.takes(es, .gloam("hype")).map(\.key), ["es-hype"])
        XCTAssertTrue(grid.takes(es, .gloam("excited")).isEmpty)
    }

    func testLegacyKeysNameTheirGloamStyleButALanguageTakeIsNeverAnEmotion() {
        let grid = VoiceTakeGrid(base: meta("dot", language: "en"), variants: [
            ("hype", meta("dot-hype")),                       // pre-style pack
            ("es-warm", meta("dot-es-warm", language: "es")),  // pre-style acted language take
            ("es", meta("dot-es", language: "es")),
        ])
        let es = VoiceTakeGrid.Row(language: "es", isHome: false)
        let hype = grid.takes.first { $0.key == "hype" }!
        XCTAssertEqual(hype.column, .gloam("hype"))
        XCTAssertTrue(hype.styleFromLegacyKey)
        XCTAssertEqual(grid.takes(es, .gloam("warm")).map(\.key), ["es-warm"])
        XCTAssertEqual(grid.takes(es, .natural).map(\.key), ["es"])
        XCTAssertFalse(grid.takes.first { $0.key == "es" }!.styleFromLegacyKey)
    }

    func testAStyleFieldWinsOverTheKey() {
        let grid = VoiceTakeGrid(base: meta("v", language: "en"), variants: [
            ("hype", meta("v-hype", style: VoiceStyle.gloam["warm"])),
        ])
        XCTAssertEqual(grid.takes.last?.column, .gloam("warm"))
        XCTAssertEqual(grid.takes.last?.styleFromLegacyKey, false)
    }

    func testOtherVocabulariesAndUntaggedExpressionsGetTheirOwnColumnsAfterGloam() {
        let grid = VoiceTakeGrid(base: meta("v", language: "en"), variants: [
            ("sad", meta("v-sad")),
            ("growl", meta("v-growl", style: VoiceStyle(name: "growl", vocabulary: "com.example"))),
            ("angry", meta("v-angry")),
        ])
        XCTAssertEqual(names(grid), ["Natural", "Flat", "Neutral", "Warm", "Excited", "Hype", "Angry", "Sad", "Growl"])
        XCTAssertEqual(grid.rows.count, 1, "untagged takes speak the home language")
    }

    func testTagsAreNormalizedAndATakeInTheHomeLanguageSharesItsRow() {
        let grid = VoiceTakeGrid(base: meta("v", language: "en_US"), variants: [
            ("en-us", meta("v-en-us", language: "EN-us")),
        ])
        XCTAssertEqual(grid.rows.map(\.language), ["en-us"])
        XCTAssertEqual(grid.takes(grid.rows[0], .natural).map(\.key), ["base", "en-us"],
                       "both kept, default first, rather than one hidden")
    }

    func testUnstatedHomeLanguageIsAHomeRowWithNoTag() {
        let grid = VoiceTakeGrid(base: meta("v"), variants: [("es", meta("v-es", language: "es"))])
        XCTAssertNil(grid.home)
        XCTAssertEqual(grid.rows, [.init(language: nil, isHome: true), .init(language: "es", isHome: false)])
    }

    func testOriginComesFromTheTakesOwnMarkNotAPacksProvenance() {
        let grid = VoiceTakeGrid(base: meta("v", language: "en"), variants: [
            ("sad", meta("v-sad", provenance: VoiceLibrary.takeProvenance(origin: "generated", engine: "fish-s2-pro"))),
            ("warm", meta("v-warm", provenance: .object(["source": .string("latent-inversion")]))),
        ])
        let sad = grid.takes.first { $0.key == "sad" }!
        XCTAssertEqual(sad.origin, .generated)
        XCTAssertEqual(sad.engine, "fish-s2-pro")
        XCTAssertNil(grid.takes.first { $0.key == "warm" }!.origin)
    }

    // MARK: library

    private func bensonPack() throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("packs/benson.gvoice")
        return try Data(contentsOf: url)
    }

    func testBensonPackIsTwelveTakesEnglishAndSpanishTimesSixStyles() throws {
        let lib = library()
        let slug = try lib.importPack(try bensonPack()).slug
        let grid = try XCTUnwrap(lib.takeGrid(of: slug))
        XCTAssertEqual(grid.takes.count, 12)
        XCTAssertEqual(grid.rows.map(\.language), ["en", "es"])
        XCTAssertEqual(names(grid), ["Natural", "Flat", "Neutral", "Warm", "Excited", "Hype"])
        for row in grid.rows {
            for column in grid.columns {
                XCTAssertEqual(grid.takes(row, column).count, 1, "\(row) \(column)")
            }
        }
        XCTAssertEqual(grid.takes(grid.rows[1], .gloam("excited")).first?.key, "es-excited")
        XCTAssertNil(lib.takeGrid(of: "\(slug)-es"), "a take has no grid of its own")
    }

    func testEditorAddsStyledLanguageTakeAndHomeLanguageAndExportKeepsEverything() throws {
        let lib = library()
        let slug = try lib.importPack(try bensonPack()).slug
        let before = try lib.meta(slug).revision ?? 0
        let take = try lib.addLanguageTake(slug, language: "fr", style: VoiceStyle.gloam["warm"],
                                           refWav: Data([1, 2, 3]), refText: "bonjour",
                                           provenance: VoiceLibrary.takeProvenance(origin: "imported"))
        XCTAssertEqual(take.slug, "\(slug)-fr-warm")
        XCTAssertEqual(take.style, VoiceStyle.gloam["warm"])
        try lib.setHomeLanguage(slug, "en-GB")
        XCTAssertEqual(try lib.meta(slug).language, "en-GB")
        XCTAssertGreaterThan(try lib.meta(slug).revision ?? 0, before)

        let grid = try XCTUnwrap(lib.takeGrid(of: slug))
        XCTAssertEqual(grid.rows.map(\.language), ["en-gb", "es", "fr"],
                       "untagged takes follow the home language")
        let fr = try XCTUnwrap(grid.rows.last)
        XCTAssertEqual(grid.takes(fr, .gloam("warm")).first?.origin, .imported)

        let manifest = try GVoice.manifest(of: try GVoice.export(slug, from: lib))
        XCTAssertEqual(manifest.language, "en-GB")
        XCTAssertEqual(manifest.variants?.count, 13)
        XCTAssertEqual(manifest.source?["fr-warm"]?.language, "fr")
        XCTAssertEqual(manifest.source?["fr-warm"]?.style?.name, "warm")
        XCTAssertEqual(manifest.source?["es-excited"]?.style?.name, "excited")

        try lib.deleteTake(take.slug)
        XCTAssertEqual(lib.takeGrid(of: slug)?.takes.count, 12)
        XCTAssertThrowsError(try lib.deleteTake(slug), "the voice itself is not a take")
    }
}
