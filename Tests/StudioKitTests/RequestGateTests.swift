import XCTest
@testable import StudioKit

final class RequestGateTests: XCTestCase {
    func testAdmitsUpToCapacityThenRejects() async throws {
        // 1 running + 2 queued = 3 admitted; the 4th is rejected.
        let gate = RequestGate(maxConcurrent: 1, maxQueued: 2)
        let started = expectation(description: "first started")
        let holder = Task {
            try await gate.run {
                started.fulfill()
                try await Task.sleep(for: .milliseconds(300))
                return 0
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let q1 = Task { try await gate.run { 1 } }
        let q2 = Task { try await gate.run { 2 } }
        try await Task.sleep(for: .milliseconds(20))
        do {
            _ = try await gate.run { 3 }
            XCTFail("expected RequestGate.Busy")
        } catch is RequestGate.Busy {
            // expected
        }
        _ = try await holder.value
        _ = try await q1.value
        _ = try await q2.value
    }
}
