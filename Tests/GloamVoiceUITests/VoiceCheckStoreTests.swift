import XCTest
@testable import GloamVoiceUI

final class VoiceCheckStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vc-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private let sample = Qualification(chosen: .cleaned, severity: 40,
                                       problems: [.wordsMissing(match: 0.7)],
                                       findings: ["Check the transcript."], engine: "onnx",
                                       checkedAt: Date(timeIntervalSince1970: 1_800_000_000))

    func testSaveThenLoadRoundTrips() throws {
        try VoiceCheckStore.save(sample, slug: "mine", in: dir)
        XCTAssertEqual(VoiceCheckStore.load(slug: "mine", in: dir), sample)
    }

    func testUnknownSlugLoadsAsNil() {
        XCTAssertNil(VoiceCheckStore.load(slug: "nobody", in: dir))
    }

    func testACorruptFileLoadsAsNil() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: VoiceCheckStore.url(slug: "broken", in: dir))
        XCTAssertNil(VoiceCheckStore.load(slug: "broken", in: dir))
    }

    func testDeleteRemovesTheSidecar() throws {
        try VoiceCheckStore.save(sample, slug: "mine", in: dir)
        VoiceCheckStore.delete(slug: "mine", in: dir)
        XCTAssertNil(VoiceCheckStore.load(slug: "mine", in: dir))
    }

    /// The sidecar is a verdict on one master: once the master is newer, it
    /// no longer describes it.
    func testAStoredCheckOlderThanTheMasterIsStale() {
        let checked = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(VoiceCheckStore.isCurrent(checkedAt: checked, masterModified: Date(timeIntervalSince1970: 2_000)))
        XCTAssertTrue(VoiceCheckStore.isCurrent(checkedAt: checked, masterModified: Date(timeIntervalSince1970: 999)))
        XCTAssertTrue(VoiceCheckStore.isCurrent(checkedAt: checked, masterModified: nil))
    }

    // MARK: what Compose reads

    func testACurrentCheckGivesItsFindingsWithoutMeasuring() {
        let q = Qualification(chosen: .original, severity: 40, problems: [.wordsMissing(match: 0.6)],
                              findings: [ReferenceAdvice.transcriptMessage], engine: "onnx",
                              checkedAt: Date(timeIntervalSince1970: 2_000), transcript: "Hello there.")
        XCTAssertEqual(VoiceCheckStore.storedAdvice(q, referenceModified: Date(timeIntervalSince1970: 1_000),
                                                    transcript: "Hello there."),
                       [ReferenceAdvice.Finding(message: ReferenceAdvice.transcriptMessage, fix: .fixTranscript)])
    }

    func testNoCheckAStaleCheckOrAnUnknownMessageMeansMeasureAgain() {
        let fresh = Date(timeIntervalSince1970: 2_000)
        XCTAssertNil(VoiceCheckStore.storedAdvice(nil, referenceModified: nil, transcript: "t"))
        let q = Qualification(chosen: .original, severity: 0, problems: [], findings: [], engine: "onnx",
                              checkedAt: fresh, transcript: "t")
        XCTAssertNil(VoiceCheckStore.storedAdvice(q, referenceModified: fresh.addingTimeInterval(60), transcript: "t"))
        XCTAssertEqual(VoiceCheckStore.storedAdvice(q, referenceModified: fresh, transcript: "t"), [])
        let odd = Qualification(chosen: .original, severity: 0, problems: [], findings: ["From a later build."],
                                engine: "onnx", checkedAt: fresh, transcript: "t")
        XCTAssertNil(VoiceCheckStore.storedAdvice(odd, referenceModified: nil, transcript: "t"))
    }

    // Finding 5 (final review): the check describes the words too.

    func testAnEditedTranscriptMakesTheCheckStale() {
        let q = Qualification(chosen: .original, severity: 40, problems: [.wordsMissing(match: 0.6)],
                              findings: [ReferenceAdvice.transcriptMessage], engine: "onnx",
                              checkedAt: Date(timeIntervalSince1970: 2_000), transcript: "What I said at first.")
        XCTAssertNil(VoiceCheckStore.storedAdvice(q, referenceModified: nil, transcript: "What I actually said."))
        XCTAssertNotNil(VoiceCheckStore.storedAdvice(q, referenceModified: nil, transcript: " What I said at first.\n"),
                        "surrounding whitespace is not an edit")
    }

    func testAnOldSidecarWithoutATranscriptDecodesAndIsStale() throws {
        let json = """
        {"chosen":"original","severity":0,"problems":[],"findings":[],"engine":"onnx","checkedAt":"2026-09-20T10:00:00Z"}
        """
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: VoiceCheckStore.url(slug: "old", in: dir))
        let q = try XCTUnwrap(VoiceCheckStore.load(slug: "old", in: dir), "a build-19-beta sidecar must still decode")
        XCTAssertNil(q.transcript)
        XCTAssertNil(VoiceCheckStore.storedAdvice(q, referenceModified: nil, transcript: "anything"))
    }

    func testTheTranscriptSurvivesSavingAndStamping() throws {
        let q = Qualification(chosen: .original, severity: 0, problems: [], findings: [], engine: "onnx",
                              checkedAt: Date(timeIntervalSince1970: 1_800_000_000), transcript: "Hello.")
        try VoiceCheckStore.save(q.stamped(Date(timeIntervalSince1970: 1_800_000_100)), slug: "s", in: dir)
        XCTAssertEqual(VoiceCheckStore.load(slug: "s", in: dir)?.transcript, "Hello.")
    }
}
