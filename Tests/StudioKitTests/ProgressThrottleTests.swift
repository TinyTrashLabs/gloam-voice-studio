import XCTest
@testable import StudioKit

final class ProgressThrottleTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testTheFirstReportAlwaysPasses() {
        var throttle = ProgressThrottle()
        XCTAssertTrue(throttle.shouldReport(0.0, now: start))
    }

    /// The failure this exists to stop: a fast download reporting every
    /// megabyte, each report costing a full view-tree rebuild.
    func testAFloodOfTinyMovementsCollapsesToTenASecond() {
        var throttle = ProgressThrottle()
        _ = throttle.shouldReport(0, now: start)
        var passed = 0
        // One report per millisecond for a second, moving 0.1% each time.
        for tick in 1...1000 where throttle.shouldReport(
            Double(tick) * 0.001, now: start.addingTimeInterval(Double(tick) / 1000)) {
            passed += 1
        }
        XCTAssertLessThanOrEqual(passed, 11)
        XCTAssertGreaterThan(passed, 5)
    }

    /// Both conditions must hold. Time alone would still flood the opening
    /// seconds of a fast download.
    func testTimePassingIsNotEnoughOnItsOwn() {
        var throttle = ProgressThrottle()
        _ = throttle.shouldReport(0.5, now: start)
        XCTAssertFalse(throttle.shouldReport(0.5001, now: start.addingTimeInterval(60)))
    }

    /// And movement alone would still flood when the file is large.
    func testMovementIsNotEnoughOnItsOwn() {
        var throttle = ProgressThrottle()
        _ = throttle.shouldReport(0.1, now: start)
        XCTAssertFalse(throttle.shouldReport(0.9, now: start.addingTimeInterval(0.01)))
    }

    /// A download that finishes between ticks must still land on 1.0 rather
    /// than leaving the bar stopped at 0.97.
    func testForcedReportsAlwaysPass() {
        var throttle = ProgressThrottle()
        _ = throttle.shouldReport(0.97, now: start)
        XCTAssertTrue(throttle.shouldReport(1.0, force: true,
                                            now: start.addingTimeInterval(0.001)))
    }

    /// A retry recounts downwards. Leaving a stale higher number on screen is
    /// worse than one extra draw.
    func testGoingBackwardsIsReported() {
        var throttle = ProgressThrottle()
        _ = throttle.shouldReport(0.8, now: start)
        XCTAssertTrue(throttle.shouldReport(0.2, now: start.addingTimeInterval(0.2)))
    }
}
