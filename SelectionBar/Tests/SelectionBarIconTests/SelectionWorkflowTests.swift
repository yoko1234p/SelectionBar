import AppKit
import LocalWorkflowKit
import SelectionBarCore
import XCTest
@testable import SelectionBar

final class SelectionWorkflowTests: XCTestCase {
  @MainActor func testRecipesPersistOrderedStepsAndDoNotOverwriteCorruptConfiguration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SelectionWorkflowStore(root: root)
    let recipe = TextRecipe(name: "Clean", steps: [.normalizeLines, .trim, .collapseSpaces], destination: .note, targetNoteID: UUID())
    store.save(recipe)
    XCTAssertTrue(store.error.isEmpty)
    XCTAssertEqual(SelectionWorkflowStore(root: root).recipes.last, recipe)
    XCTAssertEqual(try CleanupStep.apply(recipe.steps, to: "  a   b\r\nc  "), "a b\nc")
    let file = root.appendingPathComponent("workflows.json"), broken = Data("{corrupt workflows".utf8)
    try broken.write(to: file)
    let reopened = SelectionWorkflowStore(root: root); reopened.save(recipe)
    XCTAssertFalse(reopened.error.isEmpty); XCTAssertEqual(try Data(contentsOf: file), broken)
  }
  @MainActor func testDisabledWorkflowDoesNotTouchClipboardOrBeginExternalAction() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = SelectionModel(root: root)
    XCTAssertNotEqual(model.executor.workflowDirectory, WorkflowFiles.directory)
    model.library.layout.removeAll { $0.provider.hasSuffix(".favorites") || $0.provider.hasSuffix(".vocabulary") || $0.provider.hasSuffix(".recipes") }
    let snapshot = snapshot()
    let before = NSPasteboard.general.changeCount
    model.collect(snapshot, note: UUID()); model.collectVocabulary(snapshot)
    if let recipe = model.workflows.recipes.first { model.runRecipe(recipe.id, snapshot: snapshot) }
    XCTAssertFalse(model.busy); XCTAssertEqual(NSPasteboard.general.changeCount, before)
  }
  @MainActor func testWordDraftIncludesSelectedWordSentenceAndValidatedSource() throws {
    let editor = NSTextView(); editor.string = "Yesterday was sunny. I am learning 日本語 today."
    var selected = snapshot()
    selected.localEditor = editor
    let draft = SelectionExecutor().makeDraft(selected, kind: .vocabulary)
    XCTAssertEqual(draft.text, "日本語"); XCTAssertTrue(draft.sentence?.contains("I am learning 日本語") == true)
    XCTAssertEqual(draft.source?.url, "https://example.com/article")
    XCTAssertEqual(draft.source?.application, "Fixture Browser"); XCTAssertNil(draft.targetNoteID)
    try draft.validate()
  }
  @MainActor private func snapshot() -> SelectionSnapshot {
    let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
    return SelectionSnapshot(context: ActionContext(text: "日本語", appName: "Fixture Browser", editable: true, browserURL: "https://example.com/article", browserTitle: "Fixture article"), application: .current, element: element, range: nil, anchor: .zero, capturedAt: Date(), lease: SelectionLease(element: element, text: "日本語", range: nil))
  }
}
