import Foundation
import XCTest

@testable import SelectionBarCore

final class ClassicScriptsTests: XCTestCase {
  func testClassic502OpensSettingsWhileJSAPIKeepsOrdinaryError() throws {
    let root = FileManager.default.temporaryDirectory
    let config: [String: Value] = ["applescript": .string("error \"Configure fixture\" number 502")]
    let action = ExtensionAction(id: "classic", title: "Synthetic", config: config)
    let record = ExtensionRecord(
      id: "fixture.classic", name: "Fixture", packagePath: root.path,
      digest: "fixture", config: config, actions: [action])
    let response = try JavaScriptEngine().run(
      ClassicScripts.request(action, record: record, context: ActionContext(text: "test")))
    XCTAssertNotNil(response.error)
    // A host receives the settings request before the wrapper rethrows. Offline
    // recorded effects are deliberately discarded on error, so inspect real RPC.
    var types: [String] = []
    _ = try JavaScriptEngine().run(
      ClassicScripts.request(action, record: record, context: ActionContext(text: "test")),
      host: { raw in
        let object = (try? JSONDecoder().decode([String: Value].self, from: Data(raw.utf8))) ?? [:]
        types.append(object["type"]?.string ?? "")
        return "{\"result\":null}"
      })
    XCTAssertEqual(types, ["settings"])
    let direct = try JavaScriptEngine().run(
      JavaScriptTests().request(
        "try { await popclip.runAppleScript('error \\\"ordinary\\\" number 502'); } catch(error) { return error.errorNumber; }",
        entitlements: ["script"]))
    XCTAssertNil(direct.error)
    XCTAssertEqual(direct.result, .number(502))
    XCTAssertTrue(direct.effects.isEmpty)
  }
  func testExplicitRemindersPermissionPreflightOccursBeforeScriptAndDenialStopsIt() throws {
    let request = JavaScriptTests().request(
      "return await popclip.runAppleScript('return 7',{permissions:['reminders']});",
      entitlements: ["script"])
    var requests: [[String: Value]] = []
    let response = try JavaScriptEngine().run(
      request,
      host: { raw in
        requests.append(
          (try? JSONDecoder().decode([String: Value].self, from: Data(raw.utf8))) ?? [:])
        return "{\"result\":null}"
      })
    XCTAssertNil(response.error)
    XCTAssertEqual(response.result, .number(7))
    XCTAssertEqual(requests.first?["type"], .string("permission"))
    XCTAssertEqual(requests.first?["permissions"], .array([.string("reminders")]))
    let denied = try JavaScriptEngine().run(
      request, host: { _ in "{\"error\":\"Fixture permission denied\"}" })
    XCTAssertEqual(denied.error, "Fixture permission denied")
    XCTAssertNil(denied.result)
  }
  func testInvalidAppleScriptOptionsNeverReachPermissionHost() throws {
    XCTAssertThrowsError(try ExternalScripts.appleScriptPermissions(["permissions": ["calendar"]]))
    XCTAssertThrowsError(
      try ExternalScripts.appleScriptPermissions(["handler": "run", "parameters": [3]]))
    XCTAssertThrowsError(try ExternalScripts.appleScriptPermissions(["parameters": ["fixture"]]))
    XCTAssertEqual(
      try ExternalScripts.appleScriptPermissions([
        "handler": "run", "parameters": ["fixture", true],
        "permissions": ["reminders", "reminders"],
      ]), ["reminders"])
    let invalid = try JavaScriptEngine().run(
      JavaScriptTests().request(
        "await popclip.runAppleScript('return 0',{permissions:['reminders'],parameters:['invalid']});",
        entitlements: ["script"]),
      host: { _ in
        XCTFail("Invalid options must fail before a permission prompt")
        return "{\"result\":null}"
      })
    XCTAssertNotNil(invalid.error)
  }
}
