import Foundation
import GVoiceKit
import XCTest

@testable import EngineKit

final class ReferenceTailTests: XCTestCase {
    let rate = 24000

    /// Blocks of 20 ms at the given levels (dBFS), as a steady tone.
    func blocks(_ levels: [Float]) -> [Float] {
        let block = rate / 50
        return levels.enumerated().flatMap { (b, db) -> [Float] in
            let amp = db <= -120 ? 0 : pow(10, db / 20) * Float(2).squareRoot()
            return (0 ..< block).map { i in amp * Float(sin(Double(b * block + i) * 0.2)) }
        }
    }

    let speech = [Float](repeating: -14, count: 20)
    /// Jeff's ref.wav: speech, 200 ms of quiet, then the onset of a word the
    /// clip cuts off.
    var jeffEnding: [Float] {
        speech + [-41, -48, -51, -52, -57, -54, -55, -57, -59, -64, -66, -61] + [-48, -30, -24, -17]
    }

    func testCutsAWordOnsetAfterTheLastQuiet() {
        let s = blocks(jeffEnding)
        XCTAssertEqual(ReferenceTail.end(of: s, sampleRate: rate), s.count - 4 * rate / 50)
    }

    func testLeavesAReferenceThatEndsQuiet() {
        let s = blocks(speech + [-63, -67, -73, -86, -88, -180])
        XCTAssertEqual(ReferenceTail.end(of: s, sampleRate: rate), s.count)
    }

    /// Cruz: speech fading into a -37 dB tail, then the end. No quiet to cut
    /// at, and nothing new starts -- left alone.
    func testLeavesAFadingTailWithNoQuietBeforeIt() {
        let s = blocks([Float](repeating: -16, count: 20) + [Float](repeating: -37, count: 15) + [-82])
        XCTAssertEqual(ReferenceTail.end(of: s, sampleRate: rate), s.count)
    }

    /// One quiet block between words is a gap inside speech, not an ending.
    func testIgnoresAQuietShorterThanTheMinimum() {
        let s = blocks(speech + [-60] + [-20, -15, -14])
        XCTAssertEqual(ReferenceTail.end(of: s, sampleRate: rate), s.count)
    }

    /// A faint tail after the quiet (room tone, not a word) is left alone.
    func testLeavesAFaintTailAfterTheQuiet() {
        let s = blocks(speech + [-60, -62, -64, -60] + [-48, -47])
        XCTAssertEqual(ReferenceTail.end(of: s, sampleRate: rate), s.count)
    }

    func testEmptyAndTinyInputs() {
        XCTAssertEqual(ReferenceTail.end(of: [], sampleRate: rate), 0)
        XCTAssertEqual(ReferenceTail.end(of: [0.5, 0.5], sampleRate: rate), 2)
    }

    // MARK: - WAV

    /// A 16-bit mono WAV, optionally with a chunk after `data`.
    func wav(_ samples: [Float], trailing: Data? = nil) -> Data {
        var pcm = Data()
        for s in samples {
            let v = UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))
            pcm.append(UInt8(v & 0xFF)); pcm.append(UInt8(v >> 8))
        }
        func le32(_ v: Int) -> Data { Data((0 ..< 4).map { UInt8((v >> (8 * $0)) & 0xFF) }) }
        func le16(_ v: Int) -> Data { Data((0 ..< 2).map { UInt8((v >> (8 * $0)) & 0xFF) }) }
        var body = Data("WAVE".utf8)
        body += Data("fmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(rate) + le32(rate * 2) + le16(2) + le16(16)
        body += Data("data".utf8) + le32(pcm.count) + pcm
        if let trailing { body += trailing }
        return Data("RIFF".utf8) + le32(body.count) + body
    }

    func testTrimmedWavDropsTheCutOffSoundAndKeepsAValidHeader() throws {
        let list = Data("LIST".utf8) + Data([4, 0, 0, 0]) + Data("INFO".utf8)
        let input = wav(blocks(jeffEnding), trailing: list)
        let out = ReferenceTail.trimmed(wav: input)
        let chunk = try XCTUnwrap(RefLoudness.dataChunk(in: out))
        XCTAssertEqual(chunk.length, (jeffEnding.count - 4) * (rate / 50) * 2)
        XCTAssertEqual(chunk.sampleRate, rate)
        XCTAssertEqual(out.count - 8, Int(out[4]) | Int(out[5]) << 8 | Int(out[6]) << 16 | Int(out[7]) << 24)
        XCTAssertEqual(out.suffix(list.count), list, "chunks after data survive")
        XCTAssertEqual(ReferenceTail.trimmed(wav: out), out, "a trimmed reference is left alone")
    }

    func testTrimmedWavLeavesGoodAndUnreadableInputAlone() {
        let good = wav(blocks(speech + [-63, -67, -73, -86, -88, -180]))
        XCTAssertEqual(ReferenceTail.trimmed(wav: good), good)
        let junk = Data("not a wav at all".utf8)
        XCTAssertEqual(ReferenceTail.trimmed(wav: junk), junk)
    }
}
