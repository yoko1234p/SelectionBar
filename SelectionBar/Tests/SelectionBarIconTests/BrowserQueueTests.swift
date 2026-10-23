import Foundation
import SelectionBarCore
import XCTest

@testable import SelectionBar

final class BrowserQueueTests: XCTestCase {
  @MainActor func testRapidCancelAndNewSelectionWaitForCancelledOperationDrain() async throws {
    var active = 0
    var maximum = 0
    var started = 0
    let browser = BrowserIntegration { _ in
      active += 1
      maximum = max(maximum, active)
      started += 1
      defer { active -= 1 }
      // Mimic an Apple event that cannot return at the instant of cancellation.
      await withCheckedContinuation { continuation in
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.035) { continuation.resume() }
      }
      try Task.checkCancellation()
      return .null
    }
    var requests: [Task<BrowserSelection?, Error>] = []
    for _ in 0..<25 {
      requests.append(Task { try await browser.read("synthetic") })
      await Task.yield()
      browser.cancel()
    }
    let final = Task { try await browser.read("synthetic") }
    for request in requests { _ = try? await request.value }
    _ = try await final.value
    XCTAssertLessThanOrEqual(maximum, 1)
    XCTAssertEqual(active, 0)
    XCTAssertGreaterThanOrEqual(started, 1)
    XCTAssertLessThan(started, 25)
  }
}
