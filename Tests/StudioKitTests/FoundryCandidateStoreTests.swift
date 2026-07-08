import XCTest
@testable import StudioKit

final class FoundryCandidateStoreTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("foundry-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeEntry(_ store: FoundryCandidateStore,
                   description: String = "gravelly narrator") throws -> FoundryCandidateEntry {
        try store.save(wav: Data(repeating: 0, count: 100), description: description,
                       auditionLine: "The quick brown fox.", language: "english",
                       sampleRate: 24000, seconds: 2.0, wallSeconds: 0.5)
    }

    func testSaveWritesWavAndJson() throws {
        let store = FoundryCandidateStore(directory: dir)
        let entry = try makeEntry(store)
        XCTAssertTrue(entry.id.range(of: #"^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$"#,
                                     options: .regularExpression) != nil)
        XCTAssertEqual(entry.description, "gravelly narrator")
        XCTAssertEqual(entry.auditionLine, "The quick brown fox.")
        XCTAssertEqual(entry.language, "english")
        let wav = try Data(contentsOf: dir.appendingPathComponent("\(entry.id).wav"))
        XCTAssertEqual(wav.count, 100)
    }

    func testListNewestFirst() throws {
        let store = FoundryCandidateStore(directory: dir)
        let a = try makeEntry(store, description: "one")
        let b = try makeEntry(store, description: "two")
        let listed = store.list()
        XCTAssertEqual(listed.map(\.id), [b.id, a.id].sorted(by: >))
    }

    func testListEmptyWhenDirectoryMissing() {
        XCTAssertEqual(FoundryCandidateStore(directory: dir).list().count, 0)
    }

    func testWavURLRejectsUnsafeIds() {
        let store = FoundryCandidateStore(directory: dir)
        XCTAssertThrowsError(try store.wavURL("../../etc/passwd"))
        XCTAssertThrowsError(try store.wavURL("20260611-120000-zzzz"))
    }

    func testDeleteRemovesBothFiles() throws {
        let store = FoundryCandidateStore(directory: dir)
        let entry = try makeEntry(store)
        try store.delete(entry.id)
        XCTAssertEqual(store.list().count, 0)
        XCTAssertThrowsError(try store.wavURL(entry.id))
        XCTAssertThrowsError(try store.delete(entry.id))
    }

    func testPruneKeepsNewestCap() throws {
        let store = FoundryCandidateStore(directory: dir, cap: 3)
        var ids: [String] = []
        for i in 0..<5 { ids.append(try makeEntry(store, description: "\(i)").id) }
        let kept = store.list().map(\.id)
        XCTAssertEqual(kept.count, 3)
        XCTAssertEqual(Set(kept), Set(ids.suffix(3)))
        XCTAssertThrowsError(try store.wavURL(ids[0]))
    }

    func testMutatingCapTakesEffectOnNextSave() throws {
        let store = FoundryCandidateStore(directory: dir, cap: 50)
        for i in 0..<5 { _ = try makeEntry(store, description: "\(i)") }
        store.cap = 2
        _ = try makeEntry(store, description: "six")
        XCTAssertEqual(store.list().count, 2)
    }
}
