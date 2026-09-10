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
    /// A session written before pauses and dialogue takes existed must still
    /// load: the new fields are optional precisely so an upgrade is not a
    /// migration.
    func testASessionFromAnOlderBuildDecodes() throws {
        let json = """
        {"lines":[{"id":"\(UUID().uuidString)","text":"hello","takes":[
          {"id":"take-0001","createdAt":"2026-01-01T00:00:00Z","sampleRate":24000,
           "seconds":1.0,"wallSeconds":0.5}]}]}
        """
        let session = try JSONDecoder().decode(ScriptSession.self, from: Data(json.utf8))
        XCTAssertEqual(session.lines.count, 1)
        XCTAssertNil(session.lines[0].kind)
        XCTAssertNil(session.lines[0].pauseSeconds)
        XCTAssertNil(session.lines[0].takes[0].voices)
        XCTAssertNil(session.lines[0].takes[0].words)
    }

    func testAPauseLineRoundTrips() throws {
        var session = ScriptSession(lines: [ScriptLine(text: "", kind: .pause(seconds: 1.5))])
        let data = try JSONEncoder().encode(session)
        session = try JSONDecoder().decode(ScriptSession.self, from: data)
        XCTAssertEqual(session.lines[0].pauseSeconds, 1.5)
    }

    func testASceneTakeCarriesItsVoicesAndTimings() throws {
        let store = SessionStore(directory: dir)
        let take = try store.saveTake(
            pcm: Data(count: 480), sampleRate: 24000, wallSeconds: 0.1,
            voices: ["ava", "ben"],
            words: [ScriptWordTiming(text: "hi", start: 0, end: 0.2)],
            note: "ben generated without its voice")
        XCTAssertEqual(take.voices, ["ava", "ben"])
        XCTAssertEqual(take.words?.first?.text, "hi")
        XCTAssertNotNil(take.note)
    }

}
