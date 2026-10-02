import XCTest
import GVoiceKit
@testable import GVoiceProductionKit

final class ReferenceCleanupProvenanceTests: XCTestCase {
    func testMergePreservesExistingObjectKeysAndRoundTrips() throws {
        let report = ReferenceCleanupReport.fixture
        let merged = try ReferenceCleanupProvenance.merging(report, into: .object(["license": .string("owned")]))
        guard case .object(let object) = merged else { return XCTFail("object expected") }
        XCTAssertEqual(object["license"], .string("owned"))
        XCTAssertNotNil(object["referenceCleanup"])
        let data = try JSONEncoder().encode(merged)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), merged)
    }

    func testMergePreservesScalarProvenance() throws {
        let merged = try ReferenceCleanupProvenance.merging(.fixture, into: .string("legacy"))
        guard case .object(let object) = merged else { return XCTFail("object expected") }
        XCTAssertEqual(object["previousProvenance"], .string("legacy"))
    }
}

private extension ReferenceCleanupReport {
    static var fixture: Self {
        .init(recipe: .standard(segments: [.init(startSeconds: 0, endSeconds: 1)]),
              metrics: .init(sourceDurationSeconds: 2, retainedDurationSeconds: 1,
                             sampleRate: 24_000, channels: 1, loudnessBeforeLUFS: -22,
                             loudnessAfterLUFS: -17, truePeakDbFS: -1.2,
                             clippedSampleCount: 0, sourceSHA256: "a", referenceSHA256: "b"),
              verification: .init(transcriber: "manual", transcriberVersion: nil,
                                  speechOnly: true, noOverlappingSpeaker: true,
                                  musicRemoved: nil, warnings: []))
    }
}
