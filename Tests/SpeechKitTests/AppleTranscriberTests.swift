import XCTest
import AVFAudio
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

    func testLiveTranscribesChunkedFixture() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SPEECHKIT_LIVE_TESTS"] == "1",
            "Live speech test — run with SPEECHKIT_LIVE_TESTS=1 locally")
        let granted = await AppleTranscriber.requestAuthorization()
        try XCTSkipUnless(granted, "Speech recognition not authorized")

        // Spoken fixture → WAV → feed as 0.25 s chunks.
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechkit-live-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", wav.path, "--data-format=LEI16@16000",
                         "testing one two three"]
        try say.run(); say.waitUntilExit()

        let file = try AVAudioFile(forReading: wav)
        let format = file.processingFormat
        let chunkFrames = AVAudioFrameCount(format.sampleRate / 4)
        let (audio, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: chunkFrames)
            else { break }
            try file.read(into: buffer, frameCount: chunkFrames)
            if buffer.frameLength == 0 { break }
            let samples = Array(UnsafeBufferPointer(
                start: buffer.floatChannelData![0],
                count: Int(buffer.frameLength)))
            continuation.yield(AudioChunk(samples: samples,
                                          sampleRate: format.sampleRate))
        }
        continuation.finish()

        let transcriber = AppleTranscriber(locale: Locale(identifier: "en_US"))
        var finalText = ""
        var sawPartial = false
        for try await update in transcriber.liveTranscribe(audio: audio) {
            switch update {
            case .partial: sawPartial = true
            case .final(let text): finalText = text
            }
        }
        XCTAssertTrue(sawPartial, "expected at least one partial")
        XCTAssertTrue(finalText.lowercased().contains("two"),
                      "got: \(finalText)")
    }
}
