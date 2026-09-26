import XCTest
import EngineKit
import GVoiceKit

final class LegacyVariantFoldTests: XCTestCase {
    var dir: URL!
    var layout: PackFolderLayout!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fold-\(UUID().uuidString)")
        layout = PackFolderLayout(directory: dir)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: backup)
    }
    var backup: URL { dir.deletingLastPathComponent().appendingPathComponent("\(dir.lastPathComponent).bak") }

    private func voice(_ slug: String, _ name: String, variantOf: String? = nil, at folder: URL? = nil) throws {
        let f = folder ?? dir.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        let meta = VoiceMeta(name: name, slug: slug, refText: "", createdAt: "", variantOf: variantOf)
        try JSONEncoder().encode(meta).write(to: f.appendingPathComponent("meta.json"))
        try Data([1]).write(to: f.appendingPathComponent("ref.wav"))
    }
    private func meta(_ folder: URL) throws -> VoiceMeta {
        try JSONDecoder().decode(VoiceMeta.self, from: Data(contentsOf: folder.appendingPathComponent("meta.json")))
    }

    func testParenthesisedTakeFoldsAndIsStamped() throws {
        try voice("nova", "Nova")
        try voice("nova-excited", "Nova (excited)")
        let moved = try LegacyVariantFold.run(in: layout, backup: backup, log: { _ in })
        XCTAssertEqual(moved.map(\.folder), ["nova-excited"])
        XCTAssertEqual(layout.voiceSlugs(), ["nova"])
        let m = try meta(layout.variantDir(base: "nova", key: "excited"))
        XCTAssertEqual(m.variantOf, "nova")
        XCTAssertEqual(m.slug, "nova-excited")
    }

    func testTakeWordFormFolds() throws {
        try voice("nova", "Nova")
        try voice("nova-chill", "Nova chill")
        XCTAssertEqual(LegacyVariantFold.plan(in: layout).map(\.key), ["chill"])
    }

    func testHyphenatedTakeNameFolds() throws {
        // RecordEmotionVariantSheet named takes "<Base>-<emotion>".
        try voice("dj-nova", "DJ Nova")
        try voice("dj-nova-hype", "DJ Nova-hype")
        XCTAssertEqual(LegacyVariantFold.plan(in: layout).map(\.key), ["hype"])
    }

    func testVariantOfAloneFolds() throws {
        try voice("nova", "Nova")
        try voice("nova-odd", "Something else", variantOf: "nova")
        XCTAssertEqual(LegacyVariantFold.plan(in: layout).map(\.key), ["odd"])
    }

    func testSurnameIsNotATake() throws {
        try voice("jo", "Jo")
        try voice("jo-smith", "Jo Smith")
        XCTAssertTrue(LegacyVariantFold.plan(in: layout).isEmpty)
    }

    func testNoBaseMeansNoFold() throws {
        try voice("robot-titan", "Robot (titan)")
        XCTAssertTrue(LegacyVariantFold.plan(in: layout).isEmpty)
    }

    func testMultiHyphenBase() throws {
        try voice("dnd-voice-1-evil", "DND Voice 1 - Evil")
        try voice("dnd-voice-1-evil-whisper", "DND Voice 1 - Evil (Whisper)")
        let p = LegacyVariantFold.plan(in: layout)
        XCTAssertEqual(p.first?.base, "dnd-voice-1-evil")
        XCTAssertEqual(p.first?.key, "whisper")
    }

    func testDuplicateTakeFoldsUnderAFreshKeyAndOverwritesNothing() throws {
        try voice("nova", "Nova")
        try voice("nova-excited", "Nova (excited)", variantOf: "nova", at: layout.variantDir(base: "nova", key: "excited"))
        try Data([9]).write(to: layout.variantDir(base: "nova", key: "excited").appendingPathComponent("ref.wav"))
        try voice("nova-excited", "Nova (excited)")
        let moved = try LegacyVariantFold.run(in: layout, backup: backup, log: { _ in })
        XCTAssertEqual(moved.map(\.key), ["excited-2"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("nova-excited").path),
                       "a top-level copy would hide the take at the same address")
        XCTAssertEqual(try Data(contentsOf: layout.variantDir(base: "nova", key: "excited").appendingPathComponent("ref.wav")), Data([9]))
        XCTAssertEqual(layout.variantKeys(of: "nova"), ["excited", "excited-2"])
    }

    func testChainedTakeIsNeverStranded() throws {
        try voice("dj", "DJ")
        try voice("dj-hype", "DJ (hype)")
        try voice("dj-hype-chill", "DJ (hype) chill")
        _ = try LegacyVariantFold.run(in: layout, backup: backup, log: { _ in })
        XCTAssertNotNil(layout.locate("dj-hype"))
        XCTAssertNotNil(layout.locate("dj-hype-chill"), "a take moved under a folder that is itself moving vanishes")
    }

    func testAHeldLockMeansAnotherProcessIsFolding() throws {
        try voice("nova", "Nova")
        try voice("nova-sad", "Nova (sad)")
        try Data().write(to: dir.appendingPathComponent(LegacyVariantFold.lockName))
        XCTAssertTrue(try LegacyVariantFold.run(in: layout, backup: backup, log: { _ in }).isEmpty)
        XCTAssertNotNil(layout.locate("nova-sad"))
        XCTAssertEqual(layout.voiceSlugs(), ["nova", "nova-sad"], "nothing moved while locked")
    }

    func testBackupLeavesNoPartialCopyBehind() throws {
        try voice("nova", "Nova")
        try voice("nova-sad", "Nova (sad)")
        _ = try LegacyVariantFold.run(in: layout, backup: backup, log: { _ in })
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.deletingLastPathComponent().path)
        XCTAssertFalse(siblings.contains { $0.hasPrefix(backup.lastPathComponent) && $0 != backup.lastPathComponent })
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(LegacyVariantFold.lockName).path))
    }

    func testSecondRunIsANoOpAndBackupOnlyWhenSomethingMoves() throws {
        try voice("jo", "Jo")
        XCTAssertTrue(try LegacyVariantFold.run(in: layout, backup: backup, log: { _ in }).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        try voice("jo-sad", "Jo (sad)")
        XCTAssertEqual(try LegacyVariantFold.run(in: layout, backup: backup, log: { _ in }).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("jo-sad/meta.json").path))
        XCTAssertTrue(try LegacyVariantFold.run(in: layout, backup: backup, log: { _ in }).isEmpty)
    }

    func testTakeWordsCoverEveryEmotion() {
        XCTAssertTrue(Set(Emotion.allCases.map(\.rawValue)).isSubset(of: LegacyVariantFold.takeWords))
        XCTAssertTrue(LegacyVariantFold.takeWords.isSuperset(of: ["chill", "hyped"]))
    }
}
