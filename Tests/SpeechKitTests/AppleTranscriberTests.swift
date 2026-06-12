import XCTest
@testable import SpeechKit

final class AppleTranscriberTests: XCTestCase {

    func testBatchTranscribesSpokenFixture() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SPEECHKIT_LIVE_TESTS"] == "1",
            "Live speech test — run with SPEECHKIT_LIVE_TESTS=1 locally")

        // Generate "hello world" speech with the system voice.
        let aiff = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechkit-fixture-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: aiff) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", aiff.path, "--data-format=LEI16@22050", "hello world"]
        try say.run()
        say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0)

        let granted = await AppleTranscriber.requestAuthorization()
        try XCTSkipUnless(granted, "Speech recognition not authorized on this machine")

        let transcriber = AppleTranscriber(locale: Locale(identifier: "en_US"))
        let transcript = try await transcriber.transcribe(audioURL: aiff,
                                                          languageHint: nil)
        XCTAssertTrue(transcript.text.lowercased().contains("hello"),
                      "got: \(transcript.text)")
    }
}
