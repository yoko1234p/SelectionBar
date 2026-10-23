import AppKit
import Combine
import LocalWorkflowKit
import SelectionBarCore

@MainActor final class SelectionWorkflowStore: ObservableObject {
  struct Document: Codable {
    var version = 1
    var recipes: [TextRecipe]
  }
  @Published private(set) var recipes: [TextRecipe] = []
  @Published private(set) var error = ""
  private var readOnly = false
  private let file: URL
  init(root: URL) {
    file = root.appendingPathComponent("workflows.json")
    do {
      if FileManager.default.fileExists(atPath: file.path) {
        let document = try JSONDecoder().decode(
          Document.self, from: WorkflowFiles.read(file, limit: 256_000))
        guard document.version == 1, document.recipes.count <= 50,
          Set(document.recipes.map(\.id)).count == document.recipes.count
        else { throw WorkflowError.invalid(L10n.text("配方清單版本或數量不正確。")) }
        for recipe in document.recipes { try recipe.validate() }
        recipes = document.recipes
      } else {
        recipes = [
          .init(
            name: L10n.text("清理後收藏"), steps: [.normalizeLines, .trim, .collapseSpaces],
            destination: .note)
        ]
      }
    } catch {
      self.error = error.localizedDescription
      readOnly = true
    }
  }
  func save(_ recipe: TextRecipe) {
    do {
      try recipe.validate()
      var proposed = recipes
      if let index = proposed.firstIndex(where: { $0.id == recipe.id }) {
        proposed[index] = recipe
      } else {
        proposed.append(recipe)
      }
      try commit(proposed)
    } catch { self.error = error.localizedDescription }
  }
  func remove(_ id: UUID) {
    do { try commit(recipes.filter { $0.id != id }) } catch {
      self.error = error.localizedDescription
    }
  }
  private func commit(_ values: [TextRecipe]) throws {
    guard !readOnly else { throw WorkflowError.invalid(L10n.text("配方設定未能載入，原檔保留。")) }
    guard values.count <= 50 else { throw WorkflowError.invalid(L10n.text("最多儲存 50 個配方。")) }
    try WorkflowFiles.write(
      JSONEncoder().encode(Document(recipes: values)), to: file, limit: 256_000)
    recipes = values
    error = ""
  }
}

extension SelectionExecutor {
  func makeDraft(
    _ snapshot: SelectionSnapshot, kind: WorkflowDraft.Kind, text: String? = nil,
    target: UUID? = nil
  ) -> WorkflowDraft {
    let fullText =
      kind == .vocabulary
      ? snapshot.localEditor?.string ?? (AX.read(snapshot.element, kAXValueAttribute) as? String)
      : nil
    let sentence =
      kind == .vocabulary
      ? fullText.flatMap { DraftContext.sentence(in: $0, selected: snapshot.context.text) } : nil
    return WorkflowDraft(
      kind: kind, text: text ?? snapshot.context.text, sentence: sentence,
      source: DraftSource(
        application: snapshot.context.appName, url: snapshot.context.browserURL,
        title: snapshot.context.browserTitle), targetNoteID: target)
  }
  func send(_ draft: WorkflowDraft) async throws {
    try Task.checkCancellation()
    let id = draft.kind == .note ? "local.pakwingho.edgenotes" : "local.pakwingho.notchhub"
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
      throw WorkflowError.invalid(
        L10n.text("找不到 ") + (draft.kind == .note ? "EdgeNotes。" : "NotchHub。"))
    }
    let file = try WorkflowFiles.writeDraft(draft, in: workflowDirectory)
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = draft.kind == .vocabulary || draft.targetNoteID == nil
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      NSWorkspace.shared.open([file], withApplicationAt: app, configuration: configuration) {
        _, error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }
}
