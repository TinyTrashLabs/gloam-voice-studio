import XCTest
@testable import StudioKit

@MainActor
final class APILogTests: XCTestCase {
    func testRingBufferCapsAt500() {
        let log = APILog(capacity: 3)
        for i in 0..<5 { log.append(.init(method: "GET", path: "/x\(i)", status: 200)) }
        XCTAssertEqual(log.entries.count, 3)
        // newest-first ordering
        XCTAssertEqual(log.entries.first?.path, "/x4")
        XCTAssertEqual(log.entries.last?.path, "/x2")
    }

    func testClear() {
        let log = APILog(capacity: 10)
        log.append(.init(method: "GET", path: "/x", status: 200))
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
    }
}
