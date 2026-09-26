import XCTest
import GVoiceKit

final class PackFolderLayoutTests: XCTestCase {
    var dir: URL!
    var layout: PackFolderLayout!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("layout-\(UUID().uuidString)")
        layout = PackFolderLayout(directory: dir)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func touchMeta(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("meta.json"))
    }

    func testTopLevelFolderIsAVoiceEvenWithAHyphen() throws {
        try touchMeta(dir.appendingPathComponent("dj"))
        try touchMeta(dir.appendingPathComponent("dj-jeff"))
        try touchMeta(layout.variantDir(base: "dj", key: "jeff"))
        XCTAssertEqual(layout.locate("dj-jeff"), .voice("dj-jeff"))
    }

    func testVariantAddressResolvesInsideTheVoice() throws {
        try touchMeta(dir.appendingPathComponent("dnd-voice-1-evil"))
        try touchMeta(layout.variantDir(base: "dnd-voice-1-evil", key: "whisper"))
        XCTAssertEqual(layout.locate("dnd-voice-1-evil-whisper"),
                       .variant(base: "dnd-voice-1-evil", key: "whisper"))
        XCTAssertEqual(layout.folder(for: "dnd-voice-1-evil-whisper")?.standardizedFileURL,
                       dir.appendingPathComponent("dnd-voice-1-evil/variants/whisper").standardizedFileURL)
    }

    func testUnknownAddressIsNil() throws {
        try touchMeta(dir.appendingPathComponent("nova"))
        XCTAssertNil(layout.locate("nova-sad"))
        XCTAssertNil(layout.locate("ghost"))
        XCTAssertNil(layout.locate("../escape"))
    }

    func testVoiceSlugsListsOnlyTopLevelVoices() throws {
        try touchMeta(dir.appendingPathComponent("nova"))
        try touchMeta(layout.variantDir(base: "nova", key: "warm"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("junk"), withIntermediateDirectories: true)
        XCTAssertEqual(layout.voiceSlugs(), ["nova"])
        XCTAssertEqual(layout.variantKeys(of: "nova"), ["warm"])
    }

    func testDotDotIsNeverATakeKey() throws {
        try touchMeta(dir.appendingPathComponent("nova"))
        try touchMeta(layout.variantDir(base: "nova", key: "warm"))
        XCTAssertNil(layout.locate("nova-.."), "nova-.. must not resolve to nova itself")
        XCTAssertNil(layout.locate("nova-."))
    }
}
