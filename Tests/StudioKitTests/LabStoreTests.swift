import EngineKit
import XCTest
@testable import StudioKit

@MainActor
final class LabStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LabStoreTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// A 1-second 24kHz mono wav (24000 frames) so duration is exactly 1.0s.
    private func oneSecondWav() -> Data {
        WAVEncoder.encode(pcm16: PCM16.data(from: [Float](repeating: 0, count: 24000)),
                          sampleRate: 24000)
    }

    func testEnsureGroupIsIdempotentByHeading() {
        let store = LabStore(directory: dir)
        let a = store.ensureGroup(heading: "Benson ref test")
        let b = store.ensureGroup(heading: "Benson ref test")
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(store.state.groups.count, 1)
    }

    func testPutClipCopiesBytesAndComputesDuration() throws {
        let store = LabStore(directory: dir)
        let g = store.setGroup(heading: "dur")
        let clip = try store.putClip(groupID: g.id, label: "A", wav: oneSecondWav(),
                                     source: .mcp)
        XCTAssertEqual(clip.duration ?? 0, 1.0, accuracy: 0.001)
        // The bytes are copied into the store, addressable by url(for:).
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: clip).path))
        // And the group now lists it.
        XCTAssertEqual(store.group(g.id)?.clipIDs, [clip.id])
    }

    func testPutClipUnknownGroupThrows() {
        let store = LabStore(directory: dir)
        XCTAssertThrowsError(try store.putClip(groupID: "nope", label: "A", wav: oneSecondWav()))
    }

    func testRoundTripPersistsAcrossInstances() throws {
        let store = LabStore(directory: dir)
        let g = store.setGroup(heading: "persist me", listenFor: "focus on Benson")
        let clip = try store.putClip(groupID: g.id, label: "A", wav: oneSecondWav(), source: .finder)
        _ = store.addMark(clipID: clip.id, t: 12.5, note: "slurs here")
        store.setClipComment(clipID: clip.id, comment: "tinny throughout")
        store.setVerdict(groupID: g.id, verdict: "B wins")
        _ = store.addRequest(groupID: g.id, text: "render 3 more draws")

        let reloaded = LabStore(directory: dir)
        XCTAssertEqual(reloaded.state.groups.count, 1)
        XCTAssertEqual(reloaded.group(g.id)?.heading, "persist me")
        XCTAssertEqual(reloaded.group(g.id)?.verdict, "B wins")
        XCTAssertEqual(reloaded.clip(clip.id)?.comment, "tinny throughout")
        XCTAssertEqual(reloaded.clip(clip.id)?.marks.first?.note, "slurs here")
        XCTAssertEqual(reloaded.group(g.id)?.requests.first?.text, "render 3 more draws")
    }

    func testDeleteGroupRemovesClipsAndFiles() throws {
        let store = LabStore(directory: dir)
        let g = store.setGroup(heading: "gone")
        let clip = try store.putClip(groupID: g.id, label: "A", wav: oneSecondWav())
        let path = store.url(for: clip).path
        store.deleteGroup(g.id)
        XCTAssertTrue(store.state.groups.isEmpty)
        XCTAssertTrue(store.state.clips.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testFeedbackReturnsMarksCommentsVerdictAndOpenRequests() throws {
        let store = LabStore(directory: dir)
        let g = store.setGroup(heading: "fb")
        let clip = try store.putClip(groupID: g.id, label: "A", wav: oneSecondWav())
        _ = store.addMark(clipID: clip.id, t: 3.0, note: "here")
        store.setClipComment(clipID: clip.id, comment: "note")
        store.setVerdict(groupID: g.id, verdict: "A")
        let open = store.addRequest(groupID: g.id, text: "do X")!
        _ = store.addRequest(groupID: g.id, text: "already done")
        store.setRequestStatus(groupID: g.id, requestID: store.group(g.id)!.requests[1].id,
                               status: .done)

        let fb = store.feedback(groupID: g.id)
        XCTAssertEqual(fb.count, 1)
        XCTAssertEqual(fb[0].verdict, "A")
        XCTAssertEqual(fb[0].openRequests, ["do X"])
        XCTAssertEqual(fb[0].clips.first?.comment, "note")
        XCTAssertEqual(fb[0].clips.first?.marks.first?.t, 3.0)
        XCTAssertEqual(open.status, .open)
    }
}
