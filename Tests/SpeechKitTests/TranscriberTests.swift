import XCTest
@testable import SpeechKit

final class TranscriberTests: XCTestCase {

    func testFakeTranscriberBatchReturnsConfiguredText() async throws {
        let fake = FakeTranscriber(batchResult: "hello from the fake")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dummy.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let transcript = try await fake.transcribe(audioURL: url, languageHint: nil)
        XCTAssertEqual(transcript.text, "hello from the fake")
    }

    func testWavDataConvenienceWritesTempFileAndCleansUp() async throws {
        let fake = FakeTranscriber(batchResult: "via data")
        let transcript = try await fake.transcribe(wavData: Data([1, 2, 3]))
        XCTAssertEqual(transcript.text, "via data")
    }

    func testFakeTranscriberLiveEmitsPartialsThenFinal() async throws {
        let fake = FakeTranscriber(
            batchResult: "x",
            liveUpdates: [.partial("hel"), .partial("hello"), .final("hello world")])
        let (audio, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        continuation.yield(AudioChunk(samples: [0, 0, 0], sampleRate: 16000))
        continuation.finish()
        var updates: [TranscriptUpdate] = []
        for try await update in fake.liveTranscribe(audio: audio) {
            updates.append(update)
        }
        XCTAssertEqual(updates,
                       [.partial("hel"), .partial("hello"), .final("hello world")])
    }

    func testAudioChunkToPCMBufferRoundTrip() throws {
        let chunk = AudioChunk(samples: [0.1, -0.2, 0.3], sampleRate: 16000)
        let buffer = try XCTUnwrap(chunk.pcmBuffer())
        XCTAssertEqual(buffer.frameLength, 3)
        XCTAssertEqual(buffer.format.sampleRate, 16000)
        let restored = Array(UnsafeBufferPointer(
            start: buffer.floatChannelData![0], count: 3))
        XCTAssertEqual(restored, [0.1, -0.2, 0.3])
    }
}
