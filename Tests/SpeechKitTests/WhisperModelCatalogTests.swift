import XCTest
@testable import SpeechKit

final class WhisperModelCatalogTests: XCTestCase {
    func testCatalogHasDefaultAndAllEntriesAreComplete() {
        XCTAssertFalse(WhisperModelCatalog.models.isEmpty)
        XCTAssertTrue(WhisperModelCatalog.models
            .contains { $0.variant == WhisperModelCatalog.defaultVariant })
        for model in WhisperModelCatalog.models {
            XCTAssertFalse(model.variant.isEmpty)
            XCTAssertFalse(model.displayName.isEmpty)
            XCTAssertGreaterThan(model.approxBytes, 0)
        }
    }

    func testWhisperTranscriberMissingModelThrows() async {
        let transcriber = WhisperTranscriber(modelFolder: URL(
            fileURLWithPath: "/nonexistent/model/folder"))
        do {
            _ = try await transcriber.transcribe(wavData: Data([1, 2, 3]))
            XCTFail("expected throw")
        } catch let error as SpeechError {
            if case .engineUnavailable = error { } else if case .transcriptionFailed = error { } else {
                XCTFail("unexpected SpeechError: \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testWAVFileWritesValidHeader() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavfile-test.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try WAVFile.write(samples: [0.0, 0.5, -0.5], sampleRate: 16000, to: url)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(data.count, 44 + 6)   // header + 3 samples * 2 bytes
    }
}
