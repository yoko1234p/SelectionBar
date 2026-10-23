import Foundation
import XCTest

@testable import SelectionBarCore

final class SelectionIntegrityTests: XCTestCase {
  func testUnchangedSelectionCanBeUsedAfterLongAction() {
    let state = SelectionIntegrity(text: "日", range: NSRange(location: 1, length: 1), value: "a日b")
    XCTAssertTrue(state.matches(text: "日", range: NSRange(location: 1, length: 1), value: "a日b"))
  }
  func testChangedSelectionRangeIsRejectedEvenWhenTextRepeats() {
    let state = SelectionIntegrity(
      text: "word", range: NSRange(location: 0, length: 4), value: "word word")
    XCTAssertFalse(
      state.matches(text: "word", range: NSRange(location: 5, length: 4), value: "word word"))
  }
  func testDocumentEditIsRejectedAndMissingAXDataIsNotProof() {
    let state = SelectionIntegrity(
      text: "word", range: NSRange(location: 0, length: 4), value: "word before")
    XCTAssertFalse(
      state.matches(text: "word", range: NSRange(location: 0, length: 4), value: "word changed"))
    XCTAssertFalse(state.matches(text: nil, range: nil, value: nil))
  }
}
