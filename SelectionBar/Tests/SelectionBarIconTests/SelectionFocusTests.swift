import AppKit
import SelectionBarCore
import XCTest

@testable import SelectionBar

final class SelectionFocusTests: XCTestCase {
  @MainActor private func fixture() -> (NSWindow, NSTextView, NSTextView, SelectionSnapshot) {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 220), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let original = NSTextView(frame: NSRect(x: 0, y: 0, width: 190, height: 180))
    let other = NSTextView(frame: NSRect(x: 200, y: 0, width: 190, height: 180))
    original.string = "Original synthetic selection"
    other.string = "Other synthetic field"
    window.contentView?.addSubview(original)
    window.contentView?.addSubview(other)
    window.makeFirstResponder(original)
    original.setSelectedRange(NSRange(location: 0, length: 8))
    let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
    let snapshot = SelectionSnapshot(
      context: ActionContext(text: "Original", bundleIdentifier: "fixture.editor", editable: true),
      application: NSRunningApplication.current, element: element,
      range: CFRange(location: 0, length: 8),
      anchor: .zero, capturedAt: Date(), lease: SelectionLease(editor: original),
      localEditor: original)
    return (window, original, other, snapshot)
  }
  @MainActor func testChangingFocusedFieldRejectsSourceEditEvenWhenOldSelectionIsUnchanged()
    async throws
  {
    let (window, original, other, snapshot) = fixture()
    defer { window.close() }
    window.makeFirstResponder(other)
    let originalText = original.string
    let otherText = other.string
    XCTAssertTrue(
      snapshot.lease.validate(snapshot.element, editor: original),
      "The old text/range still matches; focus must be checked separately")
    do {
      try await SelectionExecutor().focus(snapshot)
      XCTFail("Must not refocus or paste into a different field")
    } catch {
      XCTAssertEqual(original.string, originalText)
      XCTAssertEqual(other.string, otherText)
      XCTAssertTrue(window.firstResponder === other)
    }
  }
  @MainActor func testCancelledPasteDoesNotWriteTheClipboardOrChangeSourceFocus() async throws {
    let (window, _, other, snapshot) = fixture()
    defer { window.close() }
    window.makeFirstResponder(other)
    let before = NSPasteboard.general.changeCount
    let task = Task { @MainActor in
      withUnsafeCurrentTask { $0?.cancel() }
      try await SelectionExecutor().paste(
        "must not write cancelled result", snapshot: snapshot, restore: false)
    }
    do {
      try await task.value
      XCTFail("Cancelled action must throw")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(NSPasteboard.general.changeCount, before)
    XCTAssertTrue(window.firstResponder === other)
  }
  @MainActor func testMissingAssociatedAppPreventsClassicBeforeStepAndAction() async throws {
    let (window, original, _, snapshot) = fixture()
    defer { window.close() }
    let config: [String: Value] = [
      "app": .object([
        "name": .string("Synthetic Missing Product"), "checkinstalled": .bool(true),
        "bundleidentifiers": .array([
          .string("fixture.selectionbar.never-installed." + UUID().uuidString)
        ]),
      ]),
      "before": .string("cut"), "shellscript": .string("exit 99"),
    ]
    let action = ExtensionAction(id: "x", title: "Fixture", config: config)
    let record = ExtensionRecord(
      id: "fixture.missing", name: "Fixture", packagePath: NSTemporaryDirectory(),
      digest: "synthetic", config: config, actions: [action])
    let executor = SelectionExecutor()
    let before = original.string
    do {
      _ = try await executor.run(
        action, record: record, context: snapshot.context, snapshot: snapshot, moduleAction: nil)
      XCTFail("Missing app must reject before running any step")
    } catch {
      XCTAssertTrue(error is MissingApplicationsError)
      XCTAssertEqual(executor.missingApplications.count, 1)
      XCTAssertEqual(original.string, before)
    }
  }
}
