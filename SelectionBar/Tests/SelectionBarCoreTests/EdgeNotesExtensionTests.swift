import Foundation
import XCTest

@testable import SelectionBarCore

final class EdgeNotesExtensionTests: XCTestCase {
  func testFailedHandoffReportsReasonFromScript() throws {
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Extensions/EdgeNotes.popclipext")
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".popclipext")
    defer { try? FileManager.default.removeItem(at: fixture) }
    try FileManager.default.copyItem(at: source, to: fixture)
    try Data("#!/bin/sh\nprintf '%s\\n' 'Synthetic handoff failure' >&2\nexit 1\n".utf8)
      .write(to: fixture.appendingPathComponent("send.sh"))
    let record = try Manifest.parsePackage(fixture)
    let response = try JavaScriptEngine().run(
      ScriptRequest(
        record: record, action: XCTUnwrap(record.actions.first),
        context: ActionContext(text: "Synthetic selection")))
    XCTAssertTrue(response.error?.contains("Synthetic handoff failure") == true)
    XCTAssertTrue(response.effects.isEmpty)
  }
}
