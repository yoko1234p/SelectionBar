import XCTest

@testable import SelectionBarCore

final class EmailDetectionTests: XCTestCase {
  func testLargePlainSelectionCanStillBecomeActionInput() {
    let text = String(repeating: "a", count: 1_000_000)
    let input = ActionContext(text: text).inputObject
    XCTAssertEqual(input["text"] as? String, text)
    XCTAssertEqual((input["data"] as? [String: Any])?["emails"] as? [String], [])
  }

  func testLongInvalidEmailCandidateDoesNotPreventFindingFollowingAddress() {
    let text = String(repeating: "a", count: 100_000) + "@invalid\nvalid+tag@example.com"
    XCTAssertEqual(ActionMatcher.emails(text), ["valid+tag@example.com"])
  }

  func testEmailBoundariesPreserveOriginalMatches() {
    XCTAssertEqual(
      ActionMatcher.emails("(A.Name+tag@example.co.uk), foo_bar@test.example; 中文 test@example.com"),
      ["A.Name+tag@example.co.uk", "foo_bar@test.example", "test@example.com"])
    XCTAssertTrue(ActionMatcher.emails("ordinary text without email").isEmpty)
  }
}
