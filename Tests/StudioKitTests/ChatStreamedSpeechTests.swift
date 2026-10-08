import XCTest
import EngineKit
@testable import StudioKit

final class ChatStreamedSpeechTests: XCTestCase {
    // MARK: scheduling

    func testOnlyTheNeuralEngineBackendStreamsChatSpeech() {
        XCTAssertTrue(ChatSpeechScheduling.streams(.qwen06BANE))
        XCTAssertTrue(ChatSpeechScheduling.streams(.qwen17BANE))
        for backend in BackendID.allCases where !backend.isQwenANE {
            XCTAssertFalse(ChatSpeechScheduling.streams(backend), backend.rawValue)
        }
    }

    func testStreamedSegmentsGoSentenceBySentence() {
        let a = "This is the first sentence of the reply, a fairly ordinary one."
        let b = "Then a second one that is about as long as the first was."
        var queue = [a, b, "Short."]
        // Two long sentences exceed the streamed cap: each goes alone.
        XCTAssertEqual(ChatSpeechScheduling.nextSegment(from: &queue, streaming: true), a)
        XCTAssertEqual(ChatSpeechScheduling.nextSegment(from: &queue, streaming: true), b + " Short.")
        XCTAssertNil(ChatSpeechScheduling.nextSegment(from: &queue, streaming: true))
    }

    func testBatchedSegmentsTakeEverythingQueuedUpToTheCap() {
        let a = "This is the first sentence of the reply, a fairly ordinary one."
        let b = "Then a second one that is about as long as the first was."
        var queue = [a, b, "Short."]
        XCTAssertEqual(ChatSpeechScheduling.nextSegment(from: &queue, streaming: false), a + " " + b + " Short.")
        XCTAssertTrue(queue.isEmpty)
        var long = Array(repeating: String(repeating: "x", count: 100), count: 4)
        let first = ChatSpeechScheduling.nextSegment(from: &long, streaming: false)!
        XCTAssertLessThan(first.count, ChatSpeechScheduling.batchedMaxChars)
        XCTAssertEqual(long.count, 2)
    }

    func testAnEmptyQueueHasNoSegment() {
        var queue: [String] = []
        XCTAssertNil(ChatSpeechScheduling.nextSegment(from: &queue, streaming: true))
        XCTAssertNil(ChatSpeechScheduling.nextSegment(from: &queue, streaming: false))
    }

    // MARK: fades

    func testFaderFadesOnlyTheSegmentEdgesNotTheChunkJoins() {
        let rate = 24000
        let chunks: [[Float]] = [Array(repeating: 1, count: 7680),     // 0.32 s first chunk
                                 Array(repeating: 1, count: 23040),
                                 Array(repeating: 1, count: 23040)]
        var fader = StreamEdgeFader(sampleRate: rate)
        var out: [Float] = []
        for c in chunks { out += fader.push(c) }
        out += fader.finish()
        let whole = chunks.flatMap { $0 }
        XCTAssertEqual(out, AudioAssembler.fadeEdges(whole, sampleRate: rate))
        // Every sample between the edge fades is untouched: no dip at a join.
        let fade = fader.fadeSamples
        XCTAssertTrue(out[fade ..< (out.count - fade)].allSatisfy { $0 == 1 })
    }

    func testFaderOnAStreamShorterThanItsFadesMatchesFadeEdges() {
        var fader = StreamEdgeFader(sampleRate: 24000)
        let tiny: [Float] = Array(repeating: 0.5, count: 50)
        let out = fader.push(tiny) + fader.finish()
        XCTAssertEqual(out, AudioAssembler.fadeEdges(tiny, sampleRate: 24000))
    }

    // MARK: pump

    @MainActor private final class Collected {
        var pieces: [[Float]] = []
        var rates: Set<Int> = []
    }

    func testPumpDeliversChunksInOrderWithFadesOnlyAtTheEdges() async throws {
        let chunks: [[Float]] = (0 ..< 5).map { i in Array(repeating: Float(i + 1) / 10, count: 4000) }
        let stream = AsyncThrowingStream<SynthesisChunk, Error> { c in
            for samples in chunks { c.yield(SynthesisChunk(samples: samples, sampleRate: 24000)) }
            c.finish()
        }
        let got = await Collected()
        let result = try await StreamedSegmentPump.run(stream, gainDb: 0) { samples, rate in
            got.pieces.append(samples); got.rates.insert(rate)
        }
        let delivered = await got.pieces.flatMap { $0 }
        let whole = chunks.flatMap { $0 }
        XCTAssertEqual(delivered, AudioAssembler.fadeEdges(whole, sampleRate: 24000))
        XCTAssertEqual(result.samples, whole)          // the saved take is unfaded
        XCTAssertEqual(result.sampleRate, 24000)
        XCTAssertFalse(result.cancelled)
        let rates = await got.rates
        XCTAssertEqual(rates, [24000])
        // Streamed: more than one delivery, i.e. playback did not wait for the end.
        let count = await got.pieces.count
        XCTAssertGreaterThan(count, 1)
    }

    func testPumpRenderErrorsPropagate() async {
        struct Boom: Error {}
        let stream = AsyncThrowingStream<SynthesisChunk, Error> { c in c.finish(throwing: Boom()) }
        do {
            _ = try await StreamedSegmentPump.run(stream, gainDb: 0) { _, _ in }
            XCTFail("expected the render error")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Stop mid-stream: the pump returns at once, reports the cut, and ends the
    /// chunk stream, which is what stops the render behind it.
    func testCancellingStopsMidStreamAndEndsTheRender() async throws {
        let terminated = Flag()
        let (stream, continuation) = AsyncThrowingStream<SynthesisChunk, Error>.makeStream()
        continuation.onTermination = { _ in terminated.set() }
        let got = await Collected()
        let task = Task {
            try await StreamedSegmentPump.run(stream, gainDb: 0) { samples, _ in
                got.pieces.append(samples)
            }
        }
        // A render that never ends on its own.
        let feeder = Task {
            while !Task.isCancelled && !terminated.isSet {
                continuation.yield(SynthesisChunk(samples: Array(repeating: 0.5, count: 2400), sampleRate: 24000))
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        while await got.pieces.count < 3 { await Task.yield() }
        task.cancel()
        let result = try await task.value
        feeder.cancel()
        XCTAssertTrue(result.cancelled)
        XCTAssertTrue(terminated.isSet, "the chunk stream must end so the render stops")
        let after = await got.pieces.count
        try await Task.sleep(nanoseconds: 30_000_000)
        let later = await got.pieces.count
        XCTAssertEqual(after, later, "nothing is delivered after Stop")
    }
}
