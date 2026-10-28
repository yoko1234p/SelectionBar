import AppKit
import Foundation
import SelectionBarCore
import XCTest

@testable import SelectionBar

final class SelectionModelTests: XCTestCase {
  @MainActor func testPasteVisibilitySupportsImagesAndRespectsEditableFields() {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let paste = BuiltInAction("app.popclip.builtin.paste")
    let plain = BuiltInAction("app.popclip.builtin.plainpaste")
    let editable = ActionContext(text: "", editable: true)
    XCTAssertFalse(paste.visible(editable, pasteboard: board))
    XCTAssertTrue(board.setData(Data([0x89, 0x50, 0x4e, 0x47]), forType: .png))
    XCTAssertTrue(paste.visible(editable, pasteboard: board))
    XCTAssertFalse(plain.visible(editable, pasteboard: board))
    XCTAssertFalse(paste.visible(ActionContext(text: "", editable: false), pasteboard: board))
    board.clearContents()
    XCTAssertTrue(board.setString("fixture", forType: .string))
    XCTAssertTrue(plain.visible(editable, pasteboard: board))
  }
  @MainActor func testInsertionToolbarDoesNotPopulateExtensions() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = SelectionModel(root: root)
    let record = ExtensionRecord(
      id: "fixture.insertion.module", name: "Must not populate", packagePath: root.path,
      digest: "synthetic", config: [:],
      actions: [ExtensionAction(id: "m", title: "Module", config: ["module": .string("missing")])])
    model.library.extensions = [record]
    model.library.layout = [LayoutEntry(id: "module", provider: record.id, order: 0)]
    let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
    var snapshot = SelectionSnapshot(
      context: ActionContext(text: "", editable: true), application: .current,
      element: element, range: nil, anchor: .zero, capturedAt: Date(),
      lease: SelectionLease(element: element, text: "", range: nil))
    snapshot.insertionOnly = true
    var renders = 0
    model.renderToolbar = { captured, state in
      renders += 1
      XCTAssertTrue(captured.insertionOnly)
      XCTAssertTrue(state.pending.isEmpty)
      XCTAssertTrue(state.actions.isEmpty)
    }
    model.prepareToolbar(snapshot)
    XCTAssertEqual(renders, 1)
  }
  @MainActor func testDisabledSpellingCannotExecuteThroughOldCandidateButton() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = SelectionModel(root: root)
    for index in model.library.layout.indices
    where model.library.layout[index].provider.hasSuffix(".spelling") {
      model.library.layout[index].enabled = false
    }
    let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
    let snapshot = SelectionSnapshot(
      context: ActionContext(text: "beuatified", editable: true), application: .current,
      element: element, range: nil, anchor: .zero, capturedAt: Date(),
      lease: SelectionLease(element: element, text: "beuatified", range: nil))
    let before = NSPasteboard.general.changeCount
    model.replaceSpelling("beautified", snapshot: snapshot, copyOnly: true)
    XCTAssertFalse(model.busy)
    XCTAssertEqual(NSPasteboard.general.changeCount, before)
  }
  @MainActor func testCorruptProfileBlocksSaveAndImportUntilExplicitRecovery() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try PrivateStore.prepare(root)
    let file = root.appendingPathComponent("library.json")
    let original = Data("{invalid retained fixture".utf8)
    try original.write(to: file)
    let model = SelectionModel(root: root)
    XCTAssertNotNil(model.storageError)
    model.library.settings.size = 45
    model.save()
    model.importOriginal()
    XCTAssertFalse(model.busy)
    XCTAssertEqual(try Data(contentsOf: file), original)
    model.recoverStore()
    XCTAssertNil(model.storageError)
    XCTAssertEqual(try PrivateStore.load(at: root), model.library)
    let archives = try FileManager.default.contentsOfDirectory(
      at: root.appendingPathComponent("Recovery"), includingPropertiesForKeys: nil)
    XCTAssertEqual(archives.count, 1)
    XCTAssertEqual(try Data(contentsOf: archives[0]), original)
  }
  @MainActor func testChangingOneInstanceOptionDoesNotChangeSibling() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = SelectionModel(root: root)
    let definition: [String: Value] = [
      "identifier": .string("language"), "type": .string("string"),
    ]
    let record = ExtensionRecord(
      id: "fixture.instance", name: "Fixture", packagePath: root.path,
      digest: "synthetic", config: ["options": .array([.object(definition)])], actions: [],
      options: ["language": .string("en")])
    model.library.extensions = [record]
    model.library.layout = [
      LayoutEntry(id: "first", provider: record.id, order: 0),
      LayoutEntry(id: "second", provider: record.id, order: 1000),
    ]
    model.library.materializeInstanceOptions()
    model.setOption(
      .string("ko"), record: try XCTUnwrap(model.library.record(forSelection: "second")),
      id: "language", definition: definition)
    XCTAssertEqual(model.library.record(forSelection: "first")?.options["language"], .string("en"))
    XCTAssertEqual(model.library.record(forSelection: "second")?.options["language"], .string("ko"))
  }
  @MainActor func testNativeFailureReportsActionAndDetailsInsteadOfDisappearing() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = SelectionModel(root: root)
    let entry = LayoutEntry(id: "unsupported", provider: "fixture.unavailable", order: 0)
    model.library.layout = [entry]
    let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
    let snapshot = SelectionSnapshot(
      context: ActionContext(text: "owned fixture"), application: NSRunningApplication.current,
      element: element, range: nil, anchor: .zero, capturedAt: Date(),
      lease: SelectionLease(element: element, text: "owned fixture", range: nil))
    var failure: ActionFailure?
    model.showFailure = { value, _ in failure = value }
    model.showResult = { _, _ in XCTFail("Failure should use the inspectable failure presentation")
    }
    model.execute(entry, snapshot: snapshot)
    for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertFalse(model.busy)
    XCTAssertEqual(failure?.title, "unavailable")
    XCTAssertTrue(failure?.message.contains("未支援") == true)
    XCTAssertNil(failure?.instanceID)
  }
  @MainActor func testDisabledInstanceAndAncestorCannotExecuteThroughStaleCallback() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = SelectionModel(root: root)
    let entry = LayoutEntry(id: "child", provider: "fixture.hidden", order: 0, parent: "disabled")
    model.library.layout = [
      LayoutEntry(id: "disabled", provider: "", enabled: false, order: 0, kind: 2), entry,
    ]
    let action = ExtensionAction(
      id: "x", title: "Must not run",
      config: ["javascript": .string("throw Error('must not execute')")])
    var record = ExtensionRecord(
      id: entry.provider, name: "Fixture", packagePath: root.path, digest: "synthetic", config: [:],
      actions: [action])
    record.instanceID = entry.id
    model.library.extensions = [record]
    let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
    let snapshot = SelectionSnapshot(
      context: ActionContext(text: "owned"), application: NSRunningApplication.current,
      element: element, range: nil, anchor: .zero, capturedAt: Date(),
      lease: SelectionLease(element: element, text: "owned", range: nil))
    model.execute(entry, snapshot: snapshot)
    XCTAssertFalse(model.busy)
    model.execute(action, record: record, snapshot: snapshot)
    XCTAssertFalse(model.busy)
    XCTAssertTrue(model.notice.isEmpty)
  }
}
