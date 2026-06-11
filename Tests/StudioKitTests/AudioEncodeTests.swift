import XCTest
@testable import StudioKit

final class AudioEncodeTests: XCTestCase {
    func testPCM16ClipsAndTruncatesLikePython() {
        let data = PCM16.data(from: [0.0, 1.0, -1.0, 2.0, -2.0, 0.5])
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            .map { Int16(littleEndian: $0) }
        // np.clip(x,-1,1)*32767 astype('<i2'): 0.5*32767=16383.5 truncates to 16383
        XCTAssertEqual(values, [0, 32767, -32767, 32767, -32767, 16383])
    }

    func testWavHeaderMatchesPythonByteForByte() {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let wav = WAVEncoder.encode(pcm16: pcm, sampleRate: 24000)
        XCTAssertEqual(wav.count, 44 + 4)
        XCTAssertEqual(wav.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(wav.subdata(in: 4..<8), UInt32(36 + 4).leData)     // riff size
        XCTAssertEqual(wav.subdata(in: 8..<16), Data("WAVEfmt ".utf8))
        XCTAssertEqual(wav.subdata(in: 16..<20), UInt32(16).leData)       // fmt size
        XCTAssertEqual(wav.subdata(in: 20..<22), UInt16(1).leData)        // PCM
        XCTAssertEqual(wav.subdata(in: 22..<24), UInt16(1).leData)        // mono
        XCTAssertEqual(wav.subdata(in: 24..<28), UInt32(24000).leData)    // sample rate
        XCTAssertEqual(wav.subdata(in: 28..<32), UInt32(48000).leData)    // byte rate
        XCTAssertEqual(wav.subdata(in: 32..<34), UInt16(2).leData)        // block align
        XCTAssertEqual(wav.subdata(in: 34..<36), UInt16(16).leData)       // bits
        XCTAssertEqual(wav.subdata(in: 36..<40), Data("data".utf8))
        XCTAssertEqual(wav.subdata(in: 40..<44), UInt32(4).leData)        // data size
        XCTAssertEqual(wav.suffix(4), pcm)
    }

    func testProvenanceWritesListInfoChunkAndUpdatesRiffSize() {
        let pcm = Data(repeating: 0, count: 8)
        let wav = WAVEncoder.encode(pcm16: pcm, sampleRate: 24000,
                                    provenance: WAVEncoder.provenanceComment)
        // ICMT payload present
        XCTAssertNotNil(wav.range(of: Data("LIST".utf8)))
        XCTAssertNotNil(wav.range(of: Data("ICMT".utf8)))
        XCTAssertNotNil(wav.range(of: Data(WAVEncoder.provenanceComment.utf8)))
        // RIFF size field == file length - 8 (chunk accounting stays valid)
        let riffSize = wav.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(Int(UInt32(littleEndian: riffSize)), wav.count - 8)
        // chunks are word-aligned
        XCTAssertEqual(wav.count % 2, 0)
    }

    func testNoProvenanceMeansNoListChunk() {
        let wav = WAVEncoder.encode(pcm16: Data(repeating: 0, count: 4), sampleRate: 24000)
        XCTAssertNil(wav.range(of: Data("LIST".utf8)))
    }
}
