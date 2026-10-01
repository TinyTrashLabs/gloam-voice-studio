import XCTest
@testable import VoiceCreation
import EngineKit

final class VoiceDesignerTests: XCTestCase {
    final class Tone: ModelProviding, @unchecked Sendable {
        final class M: SpeechModel, @unchecked Sendable {
            var sampleRate: Int { 24_000 }
            func synthesize(_ r: ProviderRequest) async throws -> [Float] {
                XCTAssertNotNil(r.instruct)
                return (0..<24_000).map { Float(sin(Double($0) * 0.05) * 0.3) }
            }
        }
        func loadModel(backend: BackendID) async throws -> any SpeechModel { M() }
        func didEvictModel() {}
    }
    func testFourAuditionsAreSavedNewestFirst() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = FoundryCandidateStore(directory: dir)
        let d = VoiceDesigner(engine: GloamEngine(provider: Tone()), store: store)
        let c = try await d.audition(description: "warm, dry British man in his 40s", line: "Hello there.", language: nil, count: 4, seed: 1)
        XCTAssertEqual(c.count, 4); XCTAssertTrue(c.allSatisfy { $0.auditionLine == "Hello there." })
        XCTAssertEqual(c.map(\.id), c.map(\.id).sorted(by: >))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.wavURL(c[0].id).path))
    }
    func testAttributesAssembleInQwenFormat() {
        XCTAssertEqual(VoiceDesignAttributes.assemble(["gender": "Male", "age": "40s", "pitch": ""]), "gender: Male.\nage: 40s.")
        XCTAssertEqual(VoiceDesignAttributes.keys.count, 12)
    }
    func testWAVFileRoundTripsThroughAVAudioFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        try WAVFile.encode(mono: [0, 0.5, -0.5, 0.25], sampleRate: 24_000).write(to: url)
        let back = try XCTUnwrap(AudioImport.wavData(fromFileAt: url))
        XCTAssertEqual(back.count, 44 + 8)
    }
}
