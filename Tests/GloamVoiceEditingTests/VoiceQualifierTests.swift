import XCTest
@testable import GloamVoiceEditing

/// Renders a stand-in per candidate: `bad` kinds come back as hiss (0s).
private struct FakeRenderer: TestRenderer {
    let bad: Set<ReferenceCandidate.Kind>
    func render(_ line: String, from c: ReferenceCandidate) async throws -> [Float] {
        bad.contains(c.kind) ? [0] : [0.5]
    }
}
private struct FakeChecker: PartChecker {
    func signalProblems(text: String, samples48k: [Float], expectedRate: Double) -> [RenderProblem] { samples48k.first == 0 ? [.hiss] : [] }
    func transcriptProblems(text: String, samples48k: [Float], expectedRate: Double) async -> [RenderProblem] { [] }
}
private func cand(_ k: ReferenceCandidate.Kind) -> ReferenceCandidate {
    .init(kind: k, url: URL(fileURLWithPath: "/tmp/\(k.rawValue).wav"), samples24k: [], transcript: "hello there friend")
}
private let quiet = RecordingCheck.Quality(seconds: 12, speechDb: -18, noiseFloorDb: -66, clippedFraction: 0)


final class VoiceQualifierTests: XCTestCase {
    func testACleanTakeRendersOnlyThePreview() async throws {
        var rendered = 0
        struct Counting: TestRenderer {
            let tick: @Sendable () -> Void
            func render(_ l: String, from c: ReferenceCandidate) async throws -> [Float] { tick(); return [0.5] }
        }
        let counter = Counter()
        let r = try await VoiceQualifier.qualify([cand(.original)], quality: quiet,
                                                 renderer: Counting { counter.bump() }, checker: FakeChecker(), engine: "test")
        rendered = counter.value
        XCTAssertEqual(r.winner.kind, .original)
        XCTAssertEqual(rendered, 1, "a clean take pays for the preview and nothing else")
    }

    func testCleanedWinsWhenTheOriginalRendersBadly() async throws {
        let r = try await VoiceQualifier.qualify([cand(.original), cand(.cleaned)], quality: quiet,
                                                 renderer: FakeRenderer(bad: [.original]), checker: FakeChecker(), engine: "test")
        XCTAssertEqual(r.winner.kind, .cleaned)
        XCTAssertEqual(r.result.problems, [])
    }

    func testATieKeepsTheOriginal() async throws {
        let r = try await VoiceQualifier.qualify([cand(.original), cand(.cleaned)], quality: quiet,
                                                 renderer: FakeRenderer(bad: []), checker: FakeChecker(), engine: "test")
        XCTAssertEqual(r.winner.kind, .original)
    }

    func testEveryCandidateFailingIsReportedNotHidden() async throws {
        let r = try await VoiceQualifier.qualify([cand(.original), cand(.cleaned)], quality: quiet,
                                                 renderer: FakeRenderer(bad: [.original, .cleaned]), checker: FakeChecker(), engine: "test")
        XCTAssertFalse(r.result.problems.isEmpty)
    }

    func testThePreviewIsTheWinnersFirstLine() async throws {
        let r = try await VoiceQualifier.qualify([cand(.original), cand(.cleaned)], quality: quiet,
                                                 renderer: FakeRenderer(bad: [.original]), checker: FakeChecker(), engine: "test")
        XCTAssertEqual(r.previews[.cleaned], [0.5])
    }

    // MARK: beyond the brief

    func testALoneTakeWhosePreviewFailsGetsTheOtherLinesToo() async throws {
        let counter = Counter()
        struct Counting: TestRenderer {
            let tick: @Sendable () -> Void
            func render(_ l: String, from c: ReferenceCandidate) async throws -> [Float] { tick(); return [0] }
        }
        let r = try await VoiceQualifier.qualify([cand(.original)], quality: quiet,
                                                 renderer: Counting { counter.bump() }, checker: FakeChecker(), engine: "test")
        XCTAssertEqual(counter.value, VoiceQualifier.testLines.count)
        XCTAssertEqual(r.result.problems.count, VoiceQualifier.testLines.count)
    }

    func testTwoCandidatesRenderEveryLineEach() async throws {
        let counter = Counter()
        struct Counting: TestRenderer {
            let tick: @Sendable () -> Void
            func render(_ l: String, from c: ReferenceCandidate) async throws -> [Float] { tick(); return [0.5] }
        }
        _ = try await VoiceQualifier.qualify([cand(.original), cand(.cleaned)], quality: quiet,
                                             renderer: Counting { counter.bump() }, checker: FakeChecker(), engine: "test")
        XCTAssertEqual(counter.value, 2 * VoiceQualifier.testLines.count)
    }

    func testTheFirstTestLineIsThePreviewLine() {
        XCTAssertEqual(VoiceQualifier.testLines.first, VoiceQualifier.previewLine)
    }

    /// A noise finding is about the raw take; once the cleaned version won,
    /// "clean it up" is advice already taken.
    func testACleanedWinnerDoesNotAdviseCleaningAgain() async throws {
        let noisy = RecordingCheck.Quality(seconds: 12, speechDb: -18, noiseFloorDb: -40, clippedFraction: 0)
        let r = try await VoiceQualifier.qualify([cand(.original), cand(.cleaned)], quality: noisy,
                                                 renderer: FakeRenderer(bad: [.original]), checker: FakeChecker(), engine: "test")
        XCTAssertEqual(r.winner.kind, .cleaned)
        let noiseAdvice = ReferenceAdvice.findings(quality: noisy, refText: "hello there friend")
            .filter { $0.fix == .cleanUpNoise }.map(\.message)
        XCTAssertFalse(noiseAdvice.isEmpty)
        XCTAssertTrue(Set(r.result.findings).isDisjoint(with: noiseAdvice))
    }
}

/// Round 1 fixes: a take let through the accept gate only because it
/// could be cleaned must not become a voice uncleaned without a word.
final class VoiceQualifierGateTests: XCTestCase {
    private let belowGate = RecordingCheck.Quality(seconds: 12, speechDb: -18, noiseFloorDb: -30, clippedFraction: 0)

    func testABelowGateTakeWithNoCleanedVersionIsRefusedWithItsProblem() {
        XCTAssertEqual(VoiceQualifier.refusal(gateProblem: "Too noisy.", candidates: [cand(.original)]), "Too noisy.")
        XCTAssertNil(VoiceQualifier.refusal(gateProblem: "Too noisy.", candidates: [cand(.original), cand(.cleaned)]))
        XCTAssertNil(VoiceQualifier.refusal(gateProblem: nil, candidates: [cand(.original)]))
    }

    func testABelowGateTakeBreaksATieTowardTheCleanedVersion() async throws {
        XCTAssertLessThan(belowGate.snrDb, RecordingCheck.minSNRDb)
        let r = try await VoiceQualifier.qualify([cand(.original), cand(.cleaned)], quality: belowGate,
                                                 renderer: FakeRenderer(bad: []), checker: FakeChecker(), engine: "test")
        XCTAssertEqual(r.winner.kind, .cleaned)
    }

    /// The stored findings describe what becomes the master (the chosen
    /// version, trimmed and levelled), not the raw take's length.
    func testFindingsAreMeasuredOnTheChosenVersion() async throws {
        // Speech-like: 0.6 s of tone, 0.4 s of silence, for 12 s.
        let samples = (0..<(24_000 * 12)).map { i -> Float in
            i % 24_000 < 14_400 ? 0.2 * sin(2 * .pi * 220 * Float(i) / 24_000) : 0
        }
        let text = String(repeating: "a", count: 190)   // 15.8 chars/s over 12 s: healthy
        let c = ReferenceCandidate(kind: .original, url: URL(fileURLWithPath: "/tmp/x.wav"), samples24k: samples, transcript: text)
        let rawButLong = RecordingCheck.Quality(seconds: 30, speechDb: -18, noiseFloorDb: -70, clippedFraction: 0)
        XCTAssertTrue(ReferenceAdvice.findings(quality: rawButLong, refText: text).contains { $0.fix == .fixTranscript },
                      "the raw length alone would call the transcript wrong")
        let r = try await VoiceQualifier.qualify([c], quality: rawButLong,
                                                 renderer: FakeRenderer(bad: []), checker: FakeChecker(), engine: "test")
        XCTAssertEqual(r.result.findings, [])
    }
}


private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
