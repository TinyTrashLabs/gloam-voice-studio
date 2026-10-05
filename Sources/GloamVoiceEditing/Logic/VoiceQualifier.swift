import Foundation

/// One version of a reference take that a voice could be cloned from.
public struct ReferenceCandidate: Sendable {
    public enum Kind: String, Codable, Sendable { case original, cleaned }
    public let kind: Kind
    public let url: URL
    public let samples24k: [Float]
    public let transcript: String

    public init(kind: Kind, url: URL, samples24k: [Float], transcript: String) {
        self.kind = kind; self.url = url; self.samples24k = samples24k; self.transcript = transcript
    }
}

public protocol TestRenderer: Sendable {
    func render(_ line: String, from candidate: ReferenceCandidate) async throws -> [Float]
}

/// What the clone-time check found, kept per voice on this phone
/// (`VoiceCheckStore`) so Compose can name the cause of a bad render
/// without measuring the reference again.
public struct Qualification: Codable, Equatable {
    public let chosen: ReferenceCandidate.Kind
    public let severity: Int
    public let problems: [RenderProblem]
    public let findings: [String]
    public let engine: String
    public let checkedAt: Date
    /// The transcript the check was made with. A findings list (e.g. "check
    /// the transcript") describes audio AND words, so an edit to the words
    /// makes it stale (`VoiceCheckStore.storedAdvice`). Nil in a sidecar
    /// written before this existed -- read as stale.
    public var transcript: String? = nil

    public init(chosen: ReferenceCandidate.Kind, severity: Int, problems: [RenderProblem], findings: [String],
                engine: String, checkedAt: Date, transcript: String? = nil) {
        self.chosen = chosen; self.severity = severity; self.problems = problems; self.findings = findings
        self.engine = engine; self.checkedAt = checkedAt; self.transcript = transcript
    }

    /// The same verdict, dated `date`: saved once the master it describes is
    /// on disk, so the master is never "newer" than its own check.
    public func stamped(_ date: Date) -> Qualification {
        Qualification(chosen: chosen, severity: severity, problems: problems,
                      findings: findings, engine: engine, checkedAt: date, transcript: transcript)
    }
}

/// Clone-time check: which version of the take clones best, judged by
/// rendering from it. A clean take is judged by its preview alone; only when
/// there is more than one candidate, or the preview failed, are the extra
/// lines rendered.
public enum VoiceQualifier {
    /// First line = the preview the person hears. The others are chosen to
    /// expose the failure modes: a question (prosody), numbers and a name
    /// (G2P + prompt bleed show up as extra words), and a long sentence
    /// (rate drift).
    public static let testLines = [
        "This is your voice, cloned on your phone. Type anything, and you'll hear it read back like this.",
        "Did you remember to call Maria about the meeting at four thirty?",
        "The train leaves from platform nine, and it usually runs a few minutes late on weekdays.",
    ]
    public static var previewLine: String { testLines[0] }

    public static func qualify(_ candidates: [ReferenceCandidate], quality: RecordingCheck.Quality,
                        renderer: TestRenderer, checker: PartChecker, engine: String) async throws
        -> (winner: ReferenceCandidate, previews: [ReferenceCandidate.Kind: [Float]], result: Qualification)
    {
        pick(try await score(candidates, renderer: renderer, checker: checker), quality: quality, engine: engine)
    }

    /// The kept version out of `scored`, every preview, and the verdict.
    public static func pick(_ scored: [Scored], quality: RecordingCheck.Quality, engine: String)
        -> (winner: ReferenceCandidate, previews: [ReferenceCandidate.Kind: [Float]], result: Qualification)
    {
        precondition(!scored.isEmpty)
        // Lowest severity wins. A tie goes to the original -- nothing is
        // processed that does not need to be -- except for a take under the
        // accept gate's noise floor: it was only let through to be cleaned.
        let preferCleaned = quality.snrDb < RecordingCheck.minSNRDb
        func rank(_ s: Scored, _ offset: Int) -> Int {
            preferCleaned ? (s.candidate.kind == .cleaned ? 0 : 1) : offset
        }
        let best = scored.enumerated().min { a, b in
            let sa = a.element.severity, sb = b.element.severity
            return sa != sb ? sa < sb : rank(a.element, a.offset) < rank(b.element, b.offset)
        }!.element
        var previews: [ReferenceCandidate.Kind: [Float]] = [:]
        for s in scored { previews[s.candidate.kind] = s.preview }
        return (best.candidate, previews, verdict(for: best, quality: quality, engine: engine))
    }

    /// One candidate's test renders, judged.
    public struct Scored: Sendable {
        public let candidate: ReferenceCandidate
        public let problems: [RenderProblem]
        /// The first test line, rendered from this candidate (48 kHz).
        public let preview: [Float]
        /// This version measured as it would be stored as the master
        /// (trimmed and levelled); nil when it has no samples to measure.
        public var masterQuality: RecordingCheck.Quality? = nil

        public init(candidate: ReferenceCandidate, problems: [RenderProblem], preview: [Float],
                    masterQuality: RecordingCheck.Quality? = nil) {
            self.candidate = candidate; self.problems = problems; self.preview = preview
            self.masterQuality = masterQuality
        }

        public var severity: Int { RenderCheck.severity(problems) }
    }

    public static func score(_ candidates: [ReferenceCandidate], renderer: TestRenderer,
                      checker: PartChecker) async throws -> [Scored] {
        precondition(!candidates.isEmpty)
        var scored: [Scored] = []
        for c in candidates {
            try Task.checkCancellation()
            var problems: [RenderProblem] = []
            var preview: [Float] = []
            // One candidate that previews cleanly needs nothing more.
            let lines = candidates.count == 1 ? [testLines[0]] : testLines
            for (i, line) in lines.enumerated() {
                let audio = try await renderer.render(line, from: c)
                if i == 0 { preview = audio }
                let p = await check(line, audio, from: c, checker)
                problems += p
                // A lone candidate whose preview failed is worth a closer look.
                if candidates.count == 1, i == 0, !p.isEmpty {
                    for extra in testLines.dropFirst() {
                        try Task.checkCancellation()
                        problems += await check(extra, try await renderer.render(extra, from: c), from: c, checker)
                    }
                }
            }
            NSLog("[qualify] %@: severity %d (%@)", c.kind.rawValue, RenderCheck.severity(problems),
                  problems.map(\.words).joined(separator: ", "))
            scored.append(Scored(candidate: c, problems: problems, preview: preview,
                                 masterQuality: masterQuality(of: c)))
        }
        return scored
    }

    private static func check(_ line: String, _ audio: [Float], from c: ReferenceCandidate,
                              _ checker: PartChecker) async -> [RenderProblem] {
        // Test renders are made at pace 1 (EngineTestRenderer), from this candidate.
        let rate = RenderCheck.expectedRate(referenceChars: c.transcript.count,
                                            referenceSeconds: Double(c.samples24k.count) / Double(ClipImport.sampleRate),
                                            pace: 1)
        // Over a reference with a noise bed, a render of pure bed must not pass as speech.
        let floor = NoiseBed.speechFloorDb(noiseFloorDb: NoiseBed.floorDb(of: c.samples24k, sampleRate: ClipImport.sampleRate))
        let p = checker.signalProblems(text: line, samples48k: audio, expectedRate: rate, speechFloorDb: floor)
        return p.isEmpty
            ? await checker.transcriptProblems(text: line, samples48k: audio, expectedRate: rate, speechFloorDb: floor)
            : p
    }

    /// The candidate as `VoiceStore.referenceWav` will store it: trimmed and
    /// levelled. Its findings are then the ones Compose would measure.
    public static func masterQuality(of c: ReferenceCandidate) -> RecordingCheck.Quality? {
        guard !c.samples24k.isEmpty else { return nil }
        return RecordingCheck.measure(RecordingCleanup.clean(c.samples24k, sampleRate: ClipImport.sampleRate),
                                      sampleRate: ClipImport.sampleRate)
    }

    /// What is stored when `s` is the version kept -- the winner, or the
    /// original when the person overrides a cleaned winner. Findings are
    /// measured on that version as it will be stored; `quality` (the raw
    /// take) stands in only when there are no samples to measure.
    public static func verdict(for s: Scored, quality: RecordingCheck.Quality, engine: String) -> Qualification {
        Qualification(chosen: s.candidate.kind, severity: s.severity, problems: s.problems,
                      findings: findings(quality: s.masterQuality ?? quality, transcript: s.candidate.transcript,
                                         chosen: s.candidate.kind).map(\.message),
                      engine: engine, checkedAt: Date(),
                      transcript: s.candidate.transcript)
    }

    /// `ReferenceAdvice` on the raw take's `quality`. Once the cleaned
    /// version is the one kept, "clean it up" is advice already taken.
    public static func findings(quality: RecordingCheck.Quality, transcript: String,
                         chosen: ReferenceCandidate.Kind) -> [ReferenceAdvice.Finding] {
        ReferenceAdvice.findings(quality: quality, refText: transcript)
            .filter { chosen == .original || $0.fix != .cleanUpNoise }
    }

    // MARK: candidates

    /// A take let through the accept gate only because it could be cleaned
    /// (`gateProblem` is what the gate said) is refused as before when no
    /// cleaned version came out of it.
    public static func refusal(gateProblem: String?, candidates: [ReferenceCandidate]) -> String? {
        guard let gateProblem, !candidates.contains(where: { $0.kind == .cleaned }) else { return nil }
        return gateProblem
    }

    /// Removes the temp WAVs of cleaned candidates, once nothing can still
    /// choose them (saved, cancelled, or a new run started). Only files this
    /// type wrote -- never the original.
    public static func discardCleaned(_ candidates: [ReferenceCandidate]) {
        for c in candidates where c.kind == .cleaned && c.url.lastPathComponent.hasPrefix("cleaned-") {
            try? FileManager.default.removeItem(at: c.url)
        }
    }

    /// A take refused only for its noise (every other check passes) is
    /// worth cleaning rather than refusing, when a denoiser ships.
    public static func failsOnlyOnNoise(_ q: RecordingCheck.Quality) -> Bool {
        guard q.snrDb < RecordingCheck.minSNRDb else { return false }
        let quietRoom = RecordingCheck.Quality(seconds: q.seconds, speechDb: q.speechDb,
                                               noiseFloorDb: q.speechDb - 100, clippedFraction: q.clippedFraction)
        return quietRoom.problem == nil
    }
}

/// How a rendered part is judged. The app's `BundledPartChecker` implements
/// it with its on-device recogniser; `VoiceQualifier` and the render guard
/// only ever see this.
public protocol PartChecker: Sendable {
    /// Milliseconds: hiss, silence, clipping, length against the text.
    /// `expectedRate` is the chars/s this voice should read at, at the pace
    /// the engine honoured (`RenderCheck.expectedRate`). `speechFloorDb` is
    /// `NoiseBed.speechFloorDb` of the reference (pass it to `RenderCheck.signal`).
    func signalProblems(text: String, samples48k: [Float], expectedRate: Double, speechFloorDb: Float) -> [RenderProblem]
    /// The transcript check; slower, and empty when it cannot run
    /// (non-English script, recogniser missing).
    func transcriptProblems(text: String, samples48k: [Float], expectedRate: Double, speechFloorDb: Float) async -> [RenderProblem]
}
