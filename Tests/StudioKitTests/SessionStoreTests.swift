import XCTest
@testable import StudioKit

final class SessionStoreTests: XCTestCase {
    var dir: URL!
    var store: SessionStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-\(UUID().uuidString)")
        store = SessionStore(directory: dir)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testLoadEmptyWhenNothingSaved() {
        XCTAssertEqual(store.load().lines.count, 0)
    }

    func testSaveAndReloadRoundTrips() throws {
        var session = ScriptSession()
        var line = ScriptLine(text: "Hello there")
        line.voiceSlug = "cruz"
        line.emotion = "hype"
        session.lines = [line]
        try store.save(session)
        let loaded = store.load()
        XCTAssertEqual(loaded.lines.count, 1)
        XCTAssertEqual(loaded.lines[0].text, "Hello there")
        XCTAssertEqual(loaded.lines[0].voiceSlug, "cruz")
        XCTAssertEqual(loaded.lines[0].emotion, "hype")
    }

    func testTakeAudioRoundTrips() throws {
        let pcm = PCM16.data(from: [0.1, -0.1, 0.2])
        let take = try store.saveTake(pcm: pcm, sampleRate: 24000, wallSeconds: 1.5)
        XCTAssertEqual(take.sampleRate, 24000)
        XCTAssertEqual(take.wallSeconds, 1.5, accuracy: 0.001)
        let url = try store.takeWavURL(take.id)
        let wav = try Data(contentsOf: url)
        XCTAssertEqual(wav.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(wav.count, 44 + pcm.count)
        // pcm16 accessor strips the header back off
        XCTAssertEqual(try store.takePCM(take.id), pcm)
    }

    func testDeleteTakeRemovesAudio() throws {
        let take = try store.saveTake(pcm: Data(repeating: 0, count: 4),
                                      sampleRate: 24000, wallSeconds: 1)
        store.deleteTake(take.id)
        XCTAssertThrowsError(try store.takeWavURL(take.id))
    }

    func testTakeIDsArePathSafe() throws {
        let take = try store.saveTake(pcm: Data(repeating: 0, count: 2),
                                      sampleRate: 24000, wallSeconds: 1)
        XCTAssertNil(take.id.rangeOfCharacter(
            from: CharacterSet(charactersIn: "/\\.")))
        XCTAssertThrowsError(try store.takeWavURL("../escape"))
    }
}
