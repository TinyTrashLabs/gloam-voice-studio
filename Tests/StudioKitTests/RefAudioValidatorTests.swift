import XCTest
@testable import StudioKit

final class RefAudioValidatorTests: XCTestCase {
    func wavFile(seconds: Double, sampleRate: Int = 24000) throws -> URL {
        let samples = [Float](repeating: 0.1, count: Int(seconds * Double(sampleRate)))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ref-\(UUID().uuidString).wav")
        try WAVEncoder.encode(pcm16: PCM16.data(from: samples), sampleRate: sampleRate)
            .write(to: url)
        return url
    }

    func testValidWavPasses() throws {
        let url = try wavFile(seconds: 5)
        let duration = try RefAudioValidator.validate(url: url)
        XCTAssertEqual(duration, 5.0, accuracy: 0.05)
    }

    func testTooShortThrows() throws {
        let url = try wavFile(seconds: 0.4)
        XCTAssertThrowsError(try RefAudioValidator.validate(url: url)) {
            guard case .invalidRefAudio = $0 as? StudioError else {
                return XCTFail("expected invalidRefAudio")
            }
        }
    }

    func testGarbageFileThrows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("junk-\(UUID().uuidString).wav")
        try Data([0xCA, 0xFE, 0xBA, 0xBE]).write(to: url)
        XCTAssertThrowsError(try RefAudioValidator.validate(url: url)) {
            guard case .invalidRefAudio = $0 as? StudioError else {
                return XCTFail("expected invalidRefAudio")
            }
        }
    }
}
