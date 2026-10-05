import XCTest
@testable import EngineKit

/// A chat reply's talk session reaches the Neural Engine model and nothing else.
final class TalkSessionPlanningTests: XCTestCase {
    private func request(_ session: String?) -> SynthesisRequest {
        SynthesisRequest(text: "Hello there.", refAudioPath: "/tmp/ref.wav", refText: "A reference.",
                         firstChunkFrames: 4, talkSession: session)
    }

    func testTheANEPlanCarriesTheTalkSession() throws {
        let plan = try RequestPlanner.plan(backend: .qwen06BANE, request: request("reply-1"))
        XCTAssertEqual(plan.talkSession, "reply-1")
        XCTAssertEqual(plan.firstChunkFrames, 4)
    }

    func testOtherBackendsNeverSeeIt() throws {
        let plan = try RequestPlanner.plan(backend: .qwen06B, request: request("reply-1"))
        XCTAssertNil(plan.talkSession)
    }

    @available(macOS 15.0, *)
    func testASessionBelongsToOneVoiceAndLanguage() {
        let a = ProviderRequest(text: "x", refAudioPath: "/v/a.wav", refText: "a", language: "en")
        var b = a; b.refAudioPath = "/v/b.wav"
        var c = a; c.language = "es"
        let key = { QwenANESpeechModel.talkSessionKey(name: "reply-1", request: $0) }
        XCTAssertEqual(key(a), key(a))
        XCTAssertNotEqual(key(a), key(b))
        XCTAssertNotEqual(key(a), key(c))
        XCTAssertNotEqual(key(a), QwenANESpeechModel.talkSessionKey(name: "reply-2", request: a))
    }
}
