import AppKit
import SelectionBarCore
import XCTest

@testable import SelectionBar

final class FailurePresentationTests: XCTestCase {
  @MainActor func testFailureDetailsRemainSelectableScrollableAndOfferInstanceSettings() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = SelectionModel(root: root)
    let bar = FloatingBar(model: model)
    defer { bar.dismiss() }
    let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
    let snapshot = SelectionSnapshot(
      context: ActionContext(text: "owned"), application: NSRunningApplication.current,
      element: element, range: nil, anchor: .zero, capturedAt: Date(),
      lease: SelectionLease(element: element, text: "owned", range: nil))
    let message = (0..<80).map { "Owned synthetic failure line \($0)" }.joined(separator: "\n")
    let content = bar.failureContent(
      ActionFailure(title: "Synthetic", message: message, instanceID: "second-instance"),
      snapshot: snapshot)
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let all = descendants(content)
    let details = try XCTUnwrap(all.compactMap { $0 as? NSTextView }.first)
    XCTAssertEqual(details.string, message)
    XCTAssertTrue(details.isSelectable)
    XCTAssertFalse(details.isEditable)
    let scroll = try XCTUnwrap(details.enclosingScrollView)
    XCTAssertTrue(scroll.hasVerticalScroller)
    XCTAssertGreaterThan(details.frame.height, 140)
    let settings = try XCTUnwrap(
      all.compactMap { $0 as? NSButton }.first {
        $0.accessibilityIdentifier() == "selectionbar.failure.settings"
      })
    var requestedSettings = false
    model.showSettings = { requestedSettings = true }
    settings.performClick(nil)
    XCTAssertTrue(requestedSettings)
    XCTAssertEqual(model.selectedExtension, "second-instance")
    XCTAssertEqual(
      bar.diagnosticGeometry["visible"], .bool(false),
      "Offscreen view construction must not order a panel")
  }
}
