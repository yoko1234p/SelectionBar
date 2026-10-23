import AppKit
import SelectionBarCore

/// A separate cancellable worker owns browser Apple events. A FIFO limits this
/// controller to one worker, including validation requests during text edits.
@MainActor
final class BrowserIntegration {
  private var tail: Task<Void, Never>?
  private var tasks: [UUID: Task<Value, Error>] = [:]
  private var workers: [UUID: ScriptSession] = [:]
  private let operation: (([String: Value]) async throws -> Value)?
  init(operation: (([String: Value]) async throws -> Value)? = nil) { self.operation = operation }
  func cancel() {
    for task in tasks.values { task.cancel() }
    for worker in workers.values { worker.cancel() }
    // Keep the admission chain until the old runtime actually exits. New
    // selections must not launch past a still-draining cancelled Apple event.
  }
  func read(_ id: String, selection: Bool = true, allowPrompt: Bool = false) async throws
    -> BrowserSelection?
  {
    let result = try await perform([
      "operation": .string("read"), "browser": .string(id),
      "captureSelection": .bool(selection), "allowPrompt": .bool(allowPrompt),
    ])
    guard result != .null else { return nil }
    return try JSONDecoder().decode(BrowserSelection.self, from: JSONEncoder().encode(result))
  }
  func authorize(_ id: String) async throws -> Bool {
    try await perform(["operation": .string("authorize"), "browser": .string(id)]).object[
      "authorized"]?.bool == true
  }
  func open(_ url: String, browser id: String, background: Bool) async throws -> Bool {
    try await perform([
      "operation": .string("open"), "browser": .string(id), "url": .string(url),
      "background": .bool(background),
    ]).object["opened"]?.bool == true
  }
  private func perform(_ values: [String: Value]) async throws -> Value {
    let identifier = UUID()
    let previous = tail
    let task = Task<Value, Error> { [weak self] in
      await previous?.value
      try Task.checkCancellation()
      guard let self else { throw CancellationError() }
      if let operation = self.operation { return try await operation(values) }
      var values = values
      values["kind"] = .string("browser")
      let literal = String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
      let config: [String: Value] = [
        "javascript": .string("return (await __externalPromise(" + literal + ")).value;"),
        "entitlements": .array([.string("script")]),
      ]
      let record = ExtensionRecord(
        id: "local.selectionbar.browser", name: "Browser",
        packagePath: PrivateStore.root.path, digest: "builtin", config: config, actions: [])
      let executable = Bundle.main.executableURL!.deletingLastPathComponent()
        .appendingPathComponent("SelectionBarRuntime").path
      let worker = ScriptSession(executable: executable)
      self.workers[identifier] = worker
      defer { self.workers.removeValue(forKey: identifier) }
      let response = try await worker.run(
        ScriptRequest(
          record: record,
          action: ExtensionAction(id: "0", title: "Browser", config: config),
          context: ActionContext(text: ""))
      ) {
        _ in throw LibraryError.invalid("Unexpected browser host effect")
      }
      try Task.checkCancellation()
      if let error = response.error { throw LibraryError.invalid(error) }
      return response.result ?? .null
    }
    tasks[identifier] = task
    tail = Task { _ = try? await task.value }
    defer { tasks.removeValue(forKey: identifier) }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}

@MainActor
final class BrowserSelectionLease {
  private var signature: String
  let browserID: String
  init(_ selection: BrowserSelection, browserID: String) {
    signature = selection.signature
    self.browserID = browserID
  }
  func validate(using integration: BrowserIntegration) async throws -> Bool {
    guard let current = try await integration.read(browserID) else { return false }
    return current.signature == signature
  }
  func refresh(using integration: BrowserIntegration) async throws {
    guard let current = try await integration.read(browserID) else { throw CancellationError() }
    signature = current.signature
  }
}
