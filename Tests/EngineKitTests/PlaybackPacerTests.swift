import XCTest
@testable import EngineKit

/// The lead-buffer rule for streamed renders: a render slower than real time holds playback until what is
/// queued covers the projected shortfall, so the read plays through instead of pausing after every chunk.
final class PlaybackPacerTests: XCTestCase {
    // MARK: Mac tuning (chat replies on qwen3-0.6b-ane)

    func testHoldsUntilARateIsKnown() {
        var p = PlaybackPacer(tuning: .mac, expectedSeconds: 10)
        p.chunkArrived(seconds: 0.32, at: 1.0)
        XCTAssertNil(p.renderRate)
        XCTAssertFalse(p.mayPlay(queued: 0.32, renderFinished: false))
        XCTAssertTrue(p.mayPlay(queued: 0.32, renderFinished: true))
    }

    func testStartsOnTheSecondChunkWhenFasterThanRealTime() {
        var p = PlaybackPacer(tuning: .mac, expectedSeconds: 10)
        p.chunkArrived(seconds: 0.32, at: 1.0)
        p.chunkArrived(seconds: 0.64, at: 1.0 + 0.64 / 1.3)   // 1.3x: not marginal, no floor
        XCTAssertEqual(p.requiredLead ?? -1, 0, accuracy: 1e-9)
        XCTAssertTrue(p.mayPlay(queued: 0.96, renderFinished: false))
    }

    func testJustAboveRealTimeKeepsOnlyAShortFloor() {
        var p = PlaybackPacer(tuning: .mac, expectedSeconds: 10)
        p.chunkArrived(seconds: 0.32, at: 1.0)
        p.chunkArrived(seconds: 0.64, at: 1.0 + 0.64 / 1.1)   // 1.1x: marginal
        // 9.04 s left x 0.1 = 0.9 s: already queued after two chunks.
        XCTAssertEqual(p.requiredLead ?? -1, 0.904, accuracy: 0.001)
        XCTAssertTrue(p.mayPlay(queued: 0.96, renderFinished: false))
    }

    func testHoldsForTheProjectedShortfallWhenSlowerThanRealTime() {
        var p = PlaybackPacer(tuning: .mac, expectedSeconds: 10)
        p.chunkArrived(seconds: 0.32, at: 1.0)
        p.chunkArrived(seconds: 0.64, at: 1.0 + 0.64 / 0.9)
        // 9.04 s left x (1/0.9 - 1) x 1.15 = 1.155 s, plus one chunk (0.64 s: the queue is a chunk lower
        // just before the last one lands) > 0.96 queued: hold.
        XCTAssertEqual(p.requiredLead ?? -1, 9.04 * (1 / 0.9 - 1) * 1.15 + 0.64, accuracy: 0.001)
        XCTAssertFalse(p.mayPlay(queued: 0.96, renderFinished: false))
        p.chunkArrived(seconds: 0.96, at: 1.0 + 1.6 / 0.9)
        // 8.08 s left: 1.03 s + a 0.8 s chunk needed, 1.92 s queued.
        XCTAssertTrue(p.mayPlay(queued: 1.92, renderFinished: false))
    }

    func testAGapBetweenRendersCountsAgainstTheRate() {
        // Sentence one renders at 1.3x, then the next sentence's prefill costs 0.8 s with no audio.
        var p = PlaybackPacer(tuning: .mac, expectedSeconds: 12)
        var t = 1.0
        for _ in 0..<4 { p.chunkArrived(seconds: 0.96, at: t); t += 0.96 / 1.3 }
        XCTAssertGreaterThan(p.renderRate ?? 0, 1.2)
        t += 0.8
        p.chunkArrived(seconds: 0.32, at: t)
        // Whole stream: 3.2 s of audio over 3.0 s of wall time.
        XCTAssertLessThan(p.renderRate ?? 9, 1.1)
    }

    func testALeadInGapHandedOverWithItsChunkIsOneArrival() {
        var p = PlaybackPacer(tuning: .mac, expectedSeconds: 10)
        p.chunkArrived(seconds: 0.15, at: 2.0)
        p.chunkArrived(seconds: 0.32, at: 2.001)
        XCTAssertNil(p.renderRate)
        XCTAssertEqual(p.receivedSeconds, 0.47, accuracy: 1e-9)
    }

    func testTheExpectationCanGrowWhileTheTextIsStillArriving() {
        var p = PlaybackPacer(tuning: .mac, expectedSeconds: 3)
        p.chunkArrived(seconds: 0.32, at: 1.0)
        p.chunkArrived(seconds: 0.64, at: 1.0 + 0.64 / 0.9)
        XCTAssertTrue(p.mayPlay(queued: 0.96, renderFinished: false))
        p.expectedSeconds = 20
        XCTAssertFalse(p.mayPlay(queued: 0.96, renderFinished: false))
    }

    func testEachDrainRaisesTheFloorBeforeResuming() {
        var p = PlaybackPacer(tuning: .mac, expectedSeconds: 10)
        p.chunkArrived(seconds: 1, at: 2.0)
        p.chunkArrived(seconds: 1, at: 2.6)
        XCTAssertTrue(p.mayPlay(queued: 2, renderFinished: false))
        p.drained()
        XCTAssertFalse(p.mayPlay(queued: 0.9, renderFinished: false))
        XCTAssertTrue(p.mayPlay(queued: 1.0, renderFinished: false))
        p.drained()
        XCTAssertFalse(p.mayPlay(queued: 1.9, renderFinished: false))
        XCTAssertTrue(p.mayPlay(queued: 2.0, renderFinished: false))
        XCTAssertEqual(p.drains, 2)
        for _ in 0..<5 { p.drained() }
        XCTAssertEqual(p.requiredLead ?? -1, PlaybackPacer.Tuning.mac.drainCap, accuracy: 1e-9)
    }

    /// End to end: a render that dips from 1.05x to 0.85x mid-reply. Playing every chunk as it lands
    /// (the old behaviour) underruns once per chunk; the pacer holds at the start, and if the dip still
    /// drains the queue, re-buffers once and plays through.
    func testOneRebufferAfterAnUnderrunInsteadOfAStutterPerChunk() {
        let rates = Array(repeating: 1.05, count: 4) + Array(repeating: 0.85, count: 14)
        let immediate = simulate(rates: rates, pacer: nil)
        XCTAssertGreaterThan(immediate.drains, 5)
        let paced = simulate(rates: rates, pacer: PlaybackPacer(tuning: .mac, expectedSeconds: expected(rates)))
        XCTAssertLessThanOrEqual(paced.drains, 1)
    }

    func testASteadySlowRenderPlaysThroughWithoutADrain() {
        for rate in [0.85, 0.9, 0.95, 1.0, 1.1] {
            let rates = Array(repeating: rate, count: 12)
            let run = simulate(rates: rates, pacer: PlaybackPacer(tuning: .mac, expectedSeconds: expected(rates)))
            XCTAssertEqual(run.drains, 0, "rate \(rate)")
        }
    }

    func testFasterThanRealTimeStartsWithinAChunkOfTheFirstSound() {
        let rates = Array(repeating: 1.3, count: 10)
        let run = simulate(rates: rates, pacer: PlaybackPacer(tuning: .mac, expectedSeconds: expected(rates)))
        // First chunk at 0.5 s; the second (0.64 s of audio at 1.3x) lands ~0.49 s later.
        XCTAssertLessThan(run.firstSound, 1.05)
        XCTAssertEqual(run.drains, 0)
    }

    // MARK: Phone tuning: the iPhone app's StreamPacer, unchanged

    func testPhoneMarginalRenderPlansOnItsWarmRate() {
        var p = PlaybackPacer(tuning: .phone, expectedSeconds: 60)
        var t = 2.0
        for _ in 0..<4 { p.chunkArrived(seconds: 1.2, at: t); t += 1.0 }
        XCTAssertEqual(p.requiredLead ?? 0, 55.2 * (1 / 0.7 - 1) * 1.15, accuracy: 0.01)
    }

    func testPhoneStartedHotPlansOnTheHotRate() {
        var p = PlaybackPacer(tuning: .phone, expectedSeconds: 60, thermalState: .critical)
        var t = 2.0
        for _ in 0..<4 { p.chunkArrived(seconds: 2, at: t); t += 1.0 }
        XCTAssertEqual(p.requiredLead ?? 0, 52 * (1 / 0.6 - 1) * 1.15, accuracy: 0.01)
    }

    func testPhoneDrainIsCapped() {
        var p = PlaybackPacer(tuning: .phone, expectedSeconds: 30)
        var t = 2.0
        for _ in 0..<6 { p.chunkArrived(seconds: 1, at: t); t += 0.7 }
        for _ in 0..<4 { p.chunkArrived(seconds: 1, at: t); t += 1.5 }
        p.drained()
        XCTAssertFalse(p.mayPlay(queued: 9.9, renderFinished: false))
        XCTAssertTrue(p.mayPlay(queued: 10, renderFinished: false))
    }

    func testEstimateFromCharacters() {
        XCTAssertEqual(PlaybackPacer.estimateSeconds(characters: 170), 10, accuracy: 0.01)
        XCTAssertEqual(PlaybackPacer.estimateSeconds(characters: 200, charactersPerSecond: 20), 10, accuracy: 0.01)
    }

    // MARK: Simulation

    private let schedule = [0.32, 0.64]   // then 0.96 s chunks (4, 8, 12 frames)
    private func chunkSeconds(_ i: Int) -> Double { i < schedule.count ? schedule[i] : 0.96 }
    private func expected(_ rates: [Double]) -> Double { rates.indices.reduce(0) { $0 + chunkSeconds($1) } }

    /// Plays a render whose chunk `i` arrives at `rates[i]` x real time (the first after 0.5 s of prefill),
    /// through a player that holds and resumes the way ChatSpeechQueue does (no pacer: plays whatever is
    /// queued, the old behaviour).
    private func simulate(rates: [Double], pacer start: PlaybackPacer?) -> (drains: Int, firstSound: Double) {
        var pacer = start
        var arrivals: [(at: Double, seconds: Double)] = []
        var t = 0.5
        for (i, rate) in rates.enumerated() {
            if i > 0 { t += chunkSeconds(i) / rate }
            arrivals.append((t, chunkSeconds(i)))
        }
        let dt = 0.001
        var now = 0.0, queued = 0.0, next = 0, playing = false, firstSound = -1.0, drains = 0
        while next < arrivals.count || queued > 1e-9 {
            while next < arrivals.count, arrivals[next].at <= now {
                pacer?.chunkArrived(seconds: arrivals[next].seconds, at: arrivals[next].at)
                queued += arrivals[next].seconds
                next += 1
            }
            let finished = next == arrivals.count
            if !playing, queued > 0,
               pacer?.mayPlay(queued: queued, renderFinished: finished) ?? true {
                playing = true
                if firstSound < 0 { firstSound = now }
            }
            if playing {
                queued -= dt
                if queued <= 0 {
                    queued = 0
                    playing = false
                    if !finished { pacer?.drained(); drains += 1 }
                }
            }
            now += dt
        }
        return (drains, firstSound)
    }
}
