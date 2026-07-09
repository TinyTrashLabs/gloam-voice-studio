import XCTest
@testable import StudioKit

final class ChatAudioAssemblyTests: XCTestCase {
    private func decodedSamples(_ wav: Data) -> [Int16] {
        wav.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            .map { Int16(littleEndian: $0) }
    }

    func testConcatenatesChunksInOrder() {
        let chunk1: [Float] = Array(repeating: 0.5, count: 1000)
        let chunk2: [Float] = Array(repeating: -0.5, count: 1000)
        let wav = ChatAudioAssembly.concatenateAndEncode([chunk1, chunk2], sampleRate: 24000)
        XCTAssertEqual(decodedSamples(wav).count, 2000)
    }

    func testEmptyChunksProduceHeaderOnlyWAV() {
        let wav = ChatAudioAssembly.concatenateAndEncode([], sampleRate: 24000)
        XCTAssertEqual(wav.count, 44)
    }

    func testEdgesFadeButBoundaryDoesNot() {
        // Two 0.5s chunks of full-scale signal — well past fadeEdges' 8ms
        // default, so only the very first/last samples of the COMBINED
        // buffer should fade; the chunk1/chunk2 boundary must be untouched.
        let chunk1: [Float] = Array(repeating: 1.0, count: 12000)
        let chunk2: [Float] = Array(repeating: 1.0, count: 12000)
        let samples = decodedSamples(
            ChatAudioAssembly.concatenateAndEncode([chunk1, chunk2], sampleRate: 24000))
        XCTAssertEqual(samples.count, 24000)
        XCTAssertLessThan(samples[0], Int16(32767 / 2))            // faded in
        XCTAssertGreaterThan(samples[12000], Int16(32767 * 0.9))   // boundary: not faded
        XCTAssertLessThan(samples[23999], Int16(32767 / 2))        // faded out
    }
}
