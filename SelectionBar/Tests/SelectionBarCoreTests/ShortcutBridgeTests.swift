import Carbon
import Foundation
import XCTest

@testable import SelectionBarCore

final class ShortcutBridgeTests: XCTestCase {
  func testShortcutsEventRetainsTypedNameAndOptionalInputWithoutExecution() throws {
    let event = try ShortcutBridge.event(name: "Synthetic \"name\"", input: "a\nb")
    let object = try XCTUnwrap(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)))
    XCTAssertEqual(object.descriptorType, typeObjectSpecifier)
    XCTAssertEqual(
      object.forKeyword(AEKeyword(keyAEKeyData))?.stringValue, "Synthetic \"name\"")
    XCTAssertEqual(event.paramDescriptor(forKeyword: 0x696E_7074)?.stringValue, "a\nb")
    XCTAssertNil(
      try ShortcutBridge.event(name: "Synthetic", input: nil).paramDescriptor(
        forKeyword: 0x696E_7074))
    XCTAssertThrowsError(try ShortcutBridge.event(name: " ", input: nil))
  }
  func testAppleScriptLocalTypedResultsWithoutAutomation() throws {
    let request = JavaScriptTests().request(
      "return await popclip.runAppleScript('return {true, 3, 2.5, \"日本語\", {\"nested\"}}');",
      entitlements: ["script"])
    let response = try JavaScriptEngine().run(request)
    XCTAssertNil(response.error)
    XCTAssertEqual(
      response.result,
      .array([.bool(true), .number(3), .number(2.5), .string("日本語"), .array([.string("nested")])]))
  }
}
