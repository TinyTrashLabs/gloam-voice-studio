import XCTest
@testable import SpeechKit

final class TranscriberTests: XCTestCase {
    func testModuleCompiles() {
        XCTAssertEqual(SpeechKitInfo.version, "0.1.0")
    }
}
