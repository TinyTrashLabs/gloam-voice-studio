import XCTest
@testable import StudioKit

/// The take a line renders from: language × style, in docs/gvoice-format.md's order
/// ((L, S) → (L) → home S → base), from the takes' fields.
final class TakeSelectionTests: XCTestCase {
    private var dirs: [URL] = []

    private func library() -> VoiceLibrary {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("take-choice-\(UUID().uuidString)")
        dirs.append(dir)
        return VoiceLibrary(directory: dir)
    }

    override func tearDown() {
        dirs.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private func bensonPack() throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("packs/benson.gvoice")
        return try Data(contentsOf: url)
    }

    private func pick(_ lib: VoiceLibrary, _ slug: String, _ language: String?, _ style: String?)
        -> (slug: String, step: TakeChoice.Step)?
    {
        lib.chooseTake(of: slug, language: language, style: style).map { ($0.slug, $0.step) }
    }

    // MARK: Benson (English home, 12 takes: en/es × natural + Gloam's five)

    func testBensonSpanishExcitedUsesSpanishExcitedTake() throws {
        let lib = library()
        let slug = try lib.importPack(try bensonPack()).slug
        XCTAssertEqual(lib.takeGrid(of: slug)?.takes.count, 12)
        let c = try XCTUnwrap(lib.chooseRecordedTake(of: slug, language: "es", style: "excited"))
        XCTAssertEqual(c.choice.slug, "\(slug)-es-excited")
        XCTAssertEqual(c.choice.step, .languageAndStyle)
        XCTAssertTrue(c.choice.carriesStyle)
        XCTAssertNotNil(c.refURL)
        // Studio's picker names and regional tags reach the same take.
        XCTAssertEqual(pick(lib, slug, "spanish", "excited")?.slug, "\(slug)-es-excited")
        XCTAssertEqual(pick(lib, slug, "es-MX", "hype")?.slug, "\(slug)-es-hype")
    }

    func testBensonEnglishExcitedUsesHomeExcitedTake() throws {
        let lib = library()
        let slug = try lib.importPack(try bensonPack()).slug
        XCTAssertEqual(pick(lib, slug, "en", "excited")?.slug, "\(slug)-excited")
        XCTAssertEqual(pick(lib, slug, "en", "excited")?.step, .homeStyle)
        XCTAssertEqual(pick(lib, slug, "english", "warm")?.slug, "\(slug)-warm")
        // Unknown language (Auto, nothing detected) reads as the home language.
        XCTAssertEqual(pick(lib, slug, nil, "excited")?.slug, "\(slug)-excited")
        XCTAssertEqual(pick(lib, slug, "auto", "excited")?.slug, "\(slug)-excited")
    }

    func testBensonNeutralIsNaturalDelivery() throws {
        let lib = library()
        let slug = try lib.importPack(try bensonPack()).slug
        XCTAssertEqual(pick(lib, slug, "en", "neutral")?.slug, slug)
        XCTAssertEqual(pick(lib, slug, "en", "neutral")?.step, .base)
        XCTAssertEqual(pick(lib, slug, "es", "neutral")?.slug, "\(slug)-es")
        XCTAssertEqual(pick(lib, slug, "es", nil)?.step, .language)
    }

    func testBensonLanguageItHasNoTakeInFallsBackToHomeStyle() throws {
        let lib = library()
        let slug = try lib.importPack(try bensonPack()).slug
        XCTAssertEqual(pick(lib, slug, "fr", "excited")?.slug, "\(slug)-excited")
        XCTAssertEqual(pick(lib, slug, "fr", "excited")?.step, .homeStyle)
        XCTAssertEqual(pick(lib, slug, "fr", nil)?.slug, slug)
    }

    func testTakePickedDirectlyIsNotRechosen() throws {
        let lib = library()
        let slug = try lib.importPack(try bensonPack()).slug
        XCTAssertNil(lib.chooseTake(of: "\(slug)-es", language: "en", style: "excited"))
    }

    func testBensonHelpTextNamesTheTakes() throws {
        let lib = library()
        let slug = try lib.importPack(try bensonPack()).slug
        let grid = try XCTUnwrap(lib.takeGrid(of: slug))
        XCTAssertEqual(grid.styleSummary(voiceName: "Benson", style: "excited"),
                       "Uses Benson's Excited take. Uses Benson's Spanish · Excited take when the line is Spanish.")
        XCTAssertEqual(grid.styleSummary(voiceName: "Benson", style: "neutral"),
                       "Uses Benson's own recording. Uses Benson's Spanish take when the line is Spanish.")
    }

    // MARK: Mandarin home (zh base, en, en-excited, excited)

    private let wav = Data([0, 1, 2])

    private func mandarinVoice(_ lib: VoiceLibrary) throws -> String {
        let slug = try lib.save(name: "Mei", refWav: wav, refText: "你好").slug
        try lib.setHomeLanguage(slug, "zh")
        try lib.addLanguageTake(slug, language: "en", refWav: wav, refText: "hello")
        try lib.addLanguageTake(slug, language: "en", style: VoiceStyle.gloam["excited"], refWav: wav, refText: "wow")
        try lib.addStyleTake(slug, style: VoiceStyle.gloam["excited"]!, refWav: wav, refText: "哇")
        return slug
    }

    func testMandarinHomeNeverAssumesEnglish() throws {
        let lib = library()
        let slug = try mandarinVoice(lib)
        XCTAssertEqual(pick(lib, slug, "zh", "excited")?.slug, "mei-excited")
        XCTAssertEqual(pick(lib, slug, "zh-Hans", nil)?.slug, "mei")
        XCTAssertEqual(pick(lib, slug, "en", "excited")?.slug, "mei-en-excited")
        XCTAssertEqual(pick(lib, slug, "en", "excited")?.step, .languageAndStyle)
        XCTAssertEqual(pick(lib, slug, "en", nil)?.slug, "mei-en")
        // Hype falls back to its near-alias at the same step before dropping the style.
        XCTAssertEqual(pick(lib, slug, "en", "hype")?.slug, "mei-en-excited")
        XCTAssertEqual(pick(lib, slug, "en", "warm")?.slug, "mei-en")
        XCTAssertEqual(pick(lib, slug, "en", "warm")?.step, .language)
        XCTAssertEqual(pick(lib, slug, "es", "excited")?.slug, "mei-excited")
        XCTAssertEqual(pick(lib, slug, nil, nil)?.slug, "mei")
    }

    func testFieldsWinOverKeySpelling() throws {
        // A take keyed "excited" that is really a warm take in English: the fields decide.
        let lib = library()
        let slug = try lib.save(name: "Kai", refWav: wav, refText: "hi").slug
        try lib.setHomeLanguage(slug, "de")
        let take = try lib.saveAt(slug: "kai-excited", name: "Kai excited", refWav: wav, refText: "x", variantOf: slug)
        try lib.setStyle(take.slug, VoiceStyle.gloam["warm"]!)
        try lib.setLanguage(take.slug, "en")
        XCTAssertEqual(pick(lib, slug, "de", "excited")?.slug, "kai")
        XCTAssertEqual(pick(lib, slug, "en", "warm")?.slug, "kai-excited")
    }

    func testUnusableTakesAreSkipped() throws {
        let lib = library()
        let slug = try lib.importPack(try bensonPack()).slug
        let c = lib.chooseTake(of: slug, language: "es", style: "excited",
                               usable: { $0.key != "es-excited" && $0.key != "es-hype" })
        XCTAssertEqual(c?.slug, "\(slug)-es")
        XCTAssertEqual(c?.step, .language)
    }

    // MARK: line language

    func testLineLanguageFollowsPickerElseConfidentDetection() {
        XCTAssertEqual(LineLanguage.of("Hello there friend", picker: "spanish"), "es")
        XCTAssertEqual(LineLanguage.of("¡Hola amigos! Esta noche tenemos la mejor música para ustedes.", picker: "auto"), "es")
        XCTAssertEqual(LineLanguage.of("Good evening everyone, welcome back to the late show.", picker: "auto"), "en")
        XCTAssertNil(LineLanguage.of("Hola amigo", picker: "auto"), "two words never switch takes")
        XCTAssertNil(LineLanguage.of("", picker: nil))
    }

    func testEngineLanguageKeepsAutoForEnglish() {
        XCTAssertEqual(LineLanguage.engineLanguage(picker: "auto", detected: "en"), "auto")
        XCTAssertEqual(LineLanguage.engineLanguage(picker: "auto", detected: nil), "auto")
        XCTAssertEqual(LineLanguage.engineLanguage(picker: "auto", detected: "es"), "spanish")
        XCTAssertEqual(LineLanguage.engineLanguage(picker: nil, detected: "zh"), "chinese")
        XCTAssertNil(LineLanguage.engineLanguage(picker: nil, detected: "nl"), "a language Qwen lacks stays auto")
        XCTAssertEqual(LineLanguage.engineLanguage(picker: "english", detected: "es"), "english",
                       "a language the user picked is passed as picked")
    }
}
