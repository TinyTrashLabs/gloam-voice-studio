import XCTest
@testable import EngineKit

final class SceneReportTests: XCTestCase {
    func testReportNamesTheSplitPoints() {
        let lines: [(index: Int, voiceSlug: String?)] =
            [(0, "ava"), (1, "ben"), (2, "cass"), (3, "ava"), (4, "dee")]
        let report = DialoguePlanner.report(for: lines)
        XCTAssertEqual(report.sceneCount, 3)
        XCTAssertEqual(report.splitAfterLines, [1, 3])
    }

    func testASingleSceneReportsNoSplits() {
        let report = DialoguePlanner.report(for: [(0, "ava"), (1, "ben")])
        XCTAssertEqual(report.sceneCount, 1)
        XCTAssertTrue(report.splitAfterLines.isEmpty)
    }

    func testAnEmptyScriptReportsNoScenes() {
        let report = DialoguePlanner.report(for: [])
        XCTAssertEqual(report.sceneCount, 0)
        XCTAssertTrue(report.splitAfterLines.isEmpty)
    }
}
