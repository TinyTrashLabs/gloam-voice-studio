import XCTest
@testable import GloamVoiceUI

final class PromptCacheTests: XCTestCase {
    private var cache: PromptCache<FakePrompt>!
    private struct FakePrompt: Codable, Equatable { var tokens: [Int]; var features: [Float]; var frames: Int; var rms: Float }
    private let prompt = FakePrompt(tokens: [1, 2], features: [0.1, 0.2], frames: 1, rms: 0.05)
    private let t0 = Date(timeIntervalSince1970: 1_000)

    override func setUp() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-\(UUID().uuidString)")
        cache = PromptCache(directory: dir)
    }

    func testMissThenHit() throws {
        XCTAssertNil(cache.prompt(for: "jeff", referenceModified: t0))
        try cache.store(prompt, for: "jeff", referenceModified: t0)
        XCTAssertEqual(cache.prompt(for: "jeff", referenceModified: t0), prompt)
    }

    func testChangedReferenceMisses() throws {
        try cache.store(prompt, for: "jeff", referenceModified: t0)
        XCTAssertNil(cache.prompt(for: "jeff", referenceModified: t0.addingTimeInterval(1)))
    }

    func testInvalidate() throws {
        try cache.store(prompt, for: "jeff", referenceModified: t0)
        cache.invalidate("jeff")
        XCTAssertNil(cache.prompt(for: "jeff", referenceModified: t0))
    }
}
