import AppKit
import Combine
import LocalWorkflowKit
import SelectionBarCore
import ServiceManagement

@MainActor
final class SelectionModel: ObservableObject {
  @Published var library: Library
  @Published var notice = ""
  @Published var permission = false
  static let conflictingApplications: Set<String> = [
    "com.pilotmoon.popclip", "com.pilotmoon.popclip-setapp",
  ]
  @Published var conflict = false
  @Published var busy = false
  @Published var selection: SelectionSnapshot?
  @Published var selectedExtension: String?
  @Published var iconRevision = 0
  @Published var storageError: String?
  @Published var settingsTab = "general"
  let workflows: SelectionWorkflowStore
  var iconsChanged: (() -> Void)?
  private var iconObserver: NSObjectProtocol?
  private var undoLibraries: [Library] = []
  var canUndoLayout: Bool { !undoLibraries.isEmpty }
  var settingsChanged: (() -> Void)?
  var showSettings: (() -> Void)?
  var dismissBar: (() -> Void)?
  var overlayFrame: (() -> CGRect?)?
  var showResult: ((String, Bool) -> Void)?
  var showFailure: ((ActionFailure, SelectionSnapshot) -> Void)?
  var showLargeText: ((String) -> Void)?
  var showBusy: ((SelectionSnapshot) -> Void)?
  var hideBusy: (() -> Void)?
  var renderToolbar: ((SelectionSnapshot, PopulationState) -> Void)?
  private var populationSession: ScriptSession?
  private lazy var toolbarPopulation = ToolbarPopulation(
    executable: Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent(
      "SelectionBarRuntime"
    ).path)
  private var operationID = 0
  private var actionTask: Task<Void, Never>?
  var reappear: (() -> Void)?
  var showActions: (([[String: Value]], ExtensionRecord, SelectionSnapshot) -> Void)?
  let executor = SelectionExecutor()
  let dataRoot: URL
  var workflowDirectory: URL {
    dataRoot.standardizedFileURL == PrivateStore.root.standardizedFileURL
      ? WorkflowFiles.directory
      : dataRoot.appendingPathComponent("WorkflowHandoffs", isDirectory: true)
  }
  init(root: URL = PrivateStore.root) {
    dataRoot = root
    workflows = SelectionWorkflowStore(root: root)
    do {
      library = try PrivateStore.load(at: root)
      storageError = nil
    } catch {
      library = .initial
      storageError = error.localizedDescription
      notice = L10n.text("設定未能載入，已停止儲存及自動顯示。原檔保留。")
    }
    executor.workflowDirectory = workflowDirectory
    iconObserver = NotificationCenter.default.addObserver(
      forName: Notification.Name("SelectionBar.ExtensionIconAssetsDidChange"),
      object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.iconRevision &+= 1
        self?.iconsChanged?()
      }
    }
  }
  func save() {
    guard storageError == nil else { return }
    do {
      try PrivateStore.save(library, at: dataRoot)
      settingsChanged?()
    } catch { notice = error.localizedDescription }
  }
  func recoverStore() {
    guard storageError != nil, !busy else { return }
    do {
      let retained = try PrivateStore.recover(at: dataRoot)
      library = try PrivateStore.load(at: dataRoot)
      storageError = nil
      undoLibraries.removeAll()
      notice = L10n.text("已重建設定；原檔保存在 Recovery／") + retained.lastPathComponent
      save()
    } catch { storageError = error.localizedDescription }
  }
  func refreshStatus() {
    permission = AXIsProcessTrusted()
    conflict = NSWorkspace.shared.runningApplications.contains {
      Self.conflictingApplications.contains($0.bundleIdentifier ?? "")
    }
  }
  func requestPermission() {
    _ = AXIsProcessTrustedWithOptions(
      [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    refreshStatus()
    settingsChanged?()
  }
  func importOriginal(reset: Bool = false) {
    guard !busy, storageError == nil else { return }
    busy = true
    operationID += 1
    let operation = operationID
    let existing = library
    let destination = dataRoot
    Task { [self] in
      do {
        let result = try await Task.detached {
          try PopClipMigration.migrate(
            destination: destination,
            existing: existing.migrationFingerprint == nil ? nil : existing,
            overwriteCustomization: reset)
        }.value
        guard operationID == operation else { return }
        library = result.0
        notice = L10n.text(
          "匯入 %1$@ 個排列項目、%2$@ 個擴充；原設定保留。", String(describing: result.1.layoutItems),
          String(describing: result.1.extensionPackages))
        settingsChanged?()
      } catch { if operationID == operation { notice = error.localizedDescription } }
      if operationID == operation { busy = false }
    }
  }
  func importExtension(_ url: URL) {
    guard !busy, storageError == nil else { return }
    busy = true
    operationID += 1
    let operation = operationID
    let destination = dataRoot
    Task { [self] in
      do {
        let record = try await Task.detached {
          try ExtensionInstaller.install(url, root: destination)
        }.value
        guard operationID == operation else { return }
        if let index = library.extensions.firstIndex(where: { $0.id == record.id }) {
          let options = library.extensions[index].options
          library.extensions[index] = record
          library.extensions[index].options = options
        } else {
          library.extensions.append(record)
          library.layout.append(
            LayoutEntry(
              id: UUID().uuidString, provider: record.id,
              order: (library.layout.map(\.order).max() ?? 0) + 1000, options: record.options))
        }
        save()
        notice = L10n.text("已匯入 %1$@；未執行擴充。", String(describing: record.name))
      } catch { if operationID == operation { notice = error.localizedDescription } }
      if operationID == operation { busy = false }
    }
  }
  func loadOptions(_ record: ExtensionRecord) {
    guard !busy, let action = record.actions.first else { return }
    busy = true
    operationID += 1
    let operation = operationID
    Task { [self] in
      do {
        let helper = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent(
          "SelectionBarRuntime"
        ).path
        let session = ScriptSession(executable: helper)
        populationSession = session
        defer { if populationSession === session { populationSession = nil } }
        let response = try await session.run(
          ScriptRequest(
            record: record, action: action, context: ActionContext(text: ""), phase: "population")
        ) { _ in throw LibraryError.invalid("Population cannot perform native actions") }
        guard operationID == operation else { return }
        if let error = response.error { throw LibraryError.invalid(error) }
        if let index = library.extensions.firstIndex(where: { $0.id == record.id }) {
          library.extensions[index].config["options"] = .array(
            response.options.map { .object(Manifest.normalized($0.mapValues(\.any))) })
          library.extensions[index].config["__hasauth"] = .bool(response.authAvailable == true)
          save()
        }
        notice = L10n.text("已讀取擴充選項；沒有執行動作。")
      } catch { if operationID == operation { notice = error.localizedDescription } }
      if operationID == operation { busy = false }
    }
  }
  func signIn(_ record: ExtensionRecord, username: String = "", password: String = "") {
    guard !busy else { return }
    busy = true
    operationID += 1
    let operation = operationID
    Task { [self] in
      do {
        let label = try await executor.authenticate(record, username: username, password: password)
        guard operationID == operation else { return }
        notice = record.name + "：" + label
      } catch { if operationID == operation { notice = error.localizedDescription } }
      if operationID == operation { busy = false }
    }
  }
  func signOut(_ record: ExtensionRecord) {
    do {
      try OwnSecrets.write("", extensionID: record.secretIdentifier)
      if record.legacySecretFallback == true { try OwnSecrets.write("", extensionID: record.id) }
      notice = record.name + L10n.text(" 已登出。")
    } catch { notice = error.localizedDescription }
  }
  func setSecret(_ value: String, record: ExtensionRecord, option: String) {
    do {
      let definition = record.config["options"]?.array.first {
        $0.object["identifier"]?.string == option
      }
      try OwnSecrets.write(
        value, extensionID: record.secretIdentifier, option: option,
        sync: definition?.object["keychain"]?.string != "local")
      notice = L10n.text("已儲存 SelectionBar 鑰匙圈。")
    } catch { notice = error.localizedDescription }
  }
  func setOption(_ value: Value, record: ExtensionRecord, id: String, definition: [String: Value]) {
    guard let index = library.layout.firstIndex(where: { $0.id == record.instanceID }),
      !["password", "secret"].contains(definition["type"]?.string ?? "")
    else { return }
    if library.layout[index].options == nil { library.layout[index].options = record.options }
    library.layout[index].options?[id] = value
    if let previous = definition["migratefrom"]?.string {
      library.layout[index].options?.removeValue(forKey: previous)
    }
    save()
  }
  func cancelAction() {
    operationID += 1
    actionTask?.cancel()
    actionTask = nil
    executor.cancel()
    populationSession?.cancel()
    populationSession = nil
    busy = false
    notice = L10n.text("已取消動作。")
    hideBusy?()
  }
  func cancelPopulation() { toolbarPopulation.cancel() }
  func authorizeBrowser(_ identifier: String) {
    guard !busy else { return }
    busy = true
    operationID += 1
    let operation = operationID
    actionTask = Task { [self] in
      do {
        let allowed = try await executor.authorizeBrowser(identifier)
        guard operationID == operation else { return }
        notice =
          allowed
          ? L10n.text("已連接瀏覽器。若選區仍無法讀取，請在瀏覽器開發選單開啟「允許 Apple Events 的 JavaScript」。")
          : L10n.text("未獲自動化授權；可在系統設定 → 私隱與保安 → 自動化更改。")
      } catch { if operationID == operation { notice = error.localizedDescription } }
      if operationID == operation { busy = false }
    }
  }
  func prepareToolbar(_ snapshot: SelectionSnapshot) {
    guard storageError == nil else { return }
    selection = snapshot
    let enabledIDs = Set(LayoutTree.enabledEntries(library.layout).map(\.id))
    let entries = library.layoutRows.map(\.entry).filter { enabledIDs.contains($0.id) }
    let jobs = entries.compactMap { entry -> PopulationJob? in
      guard var record = library.record(for: entry),
        let action = record.actions.first(where: { $0.kind == "module" })
      else { return nil }
      // Read only this app's secrets during an actual selection. Imported
      // original credentials are never consulted or copied.
      if let secret = try? OwnSecrets.read(record: record) {
        record.options["authsecret"] = .string(secret)
      }
      return PopulationJob(key: entry.id, record: record, action: action)
    }
    toolbarPopulation.populate(jobs, context: snapshot.context) { [weak self] state in
      self?.renderToolbar?(snapshot, state)
    }
  }
  func chooseImport() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.message = L10n.text("選擇 PopClip 套件或 snippet")
    if panel.runModal() == .OK, let url = panel.url { importExtension(url) }
  }
  func setLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      library.settings.launchAtLogin = enabled
      save()
    } catch { notice = error.localizedDescription }
  }
  func title(_ entry: LayoutEntry) -> String {
    if let name = entry.name, !name.isEmpty { return name }
    if let record = library.extensions.first(where: { $0.id == entry.provider }) {
      return record.name
    }
    return BuiltInAction(entry.provider).title
  }
  func move(_ entry: LayoutEntry, delta: Int) {
    editLibrary { try $0.moveEntry(entry.id, by: delta) }
  }
  func editLibrary(_ edit: (inout Library) throws -> Void) {
    do {
      var changed = library
      try edit(&changed)
      guard changed != library else { return }
      undoLibraries.append(library)
      if undoLibraries.count > 20 { undoLibraries.removeFirst() }
      library = changed
      save()
    } catch { notice = error.localizedDescription }
  }
  func undoLayout() {
    guard let previous = undoLibraries.popLast() else { return }
    library = previous
    save()
  }
  func execute(_ entry: LayoutEntry, snapshot: SelectionSnapshot) {
    guard !busy, LayoutTree.enabledEntries(library.layout).contains(where: { $0.id == entry.id })
    else { return }
    if let record = library.record(for: entry) {
      let actions = record.actions.filter {
        $0.kind == "module"
          || ActionMatcher.match($0, context: snapshot.context, options: record.effectiveOptions)
            != nil
      }
      if actions.count > 1 {
        var filtered = record
        filtered.actions = actions
        showActions?(staticMetadata(actions, record: filtered), filtered, snapshot)
        return
      }
      guard let action = actions.first else { return }
      execute(action, record: record, snapshot: snapshot)
    } else {
      busy = true
      operationID += 1
      let operation = operationID
      dismissBar?()
      showBusy?(snapshot)
      actionTask = Task { [self] in
        do {
          try await executor.performBuiltin(
            BuiltInAction(entry.provider), snapshot: snapshot,
            onResult: { [weak self] in
              guard self?.operationID == operation else { return }
              self?.showResult?($0, false)
            })
        } catch {
          if operationID == operation {
            reportFailure(error, title: BuiltInAction(entry.provider).title, snapshot: snapshot)
          }
        }
        if operationID == operation {
          busy = false
          hideBusy?()
        }
      }
    }
  }
  func replaceSpelling(_ word: String, snapshot: SelectionSnapshot, copyOnly: Bool) {
    guard !busy, snapshot.context.editable || copyOnly,
      LayoutTree.enabledEntries(library.layout).contains(where: {
        BuiltInAction($0.provider).id == "spelling"
      })
    else { return }
    busy = true
    operationID += 1
    let operation = operationID
    dismissBar?()
    showBusy?(snapshot)
    actionTask = Task { [self] in
      do {
        if copyOnly {
          try executor.copy(word)
        } else {
          try await executor.paste(word, snapshot: snapshot, restore: true)
        }
      } catch {
        if operationID == operation {
          reportFailure(error, title: L10n.text("拼字替換"), snapshot: snapshot)
        }
      }
      if operationID == operation {
        busy = false
        hideBusy?()
      }
    }
  }
  func collect(_ snapshot: SelectionSnapshot, note: UUID?) {
    guard allowsWorkflow("favorites") else { return }
    runWorkflow(L10n.text("收藏到筆記"), snapshot: snapshot) { executor in
      try await executor.send(executor.makeDraft(snapshot, kind: .note, target: note))
    }
  }
  func collectVocabulary(_ snapshot: SelectionSnapshot) {
    guard allowsWorkflow("vocabulary") else { return }
    runWorkflow(L10n.text("詞卡草稿"), snapshot: snapshot) { executor in
      try await executor.send(executor.makeDraft(snapshot, kind: .vocabulary))
    }
  }
  func runRecipe(_ id: UUID, snapshot: SelectionSnapshot) {
    guard allowsWorkflow("recipes"), let recipe = workflows.recipes.first(where: { $0.id == id })
    else { return }
    runWorkflow(recipe.name, snapshot: snapshot) { executor in
      let input = snapshot.context.text
      let worker = Task.detached { try CleanupStep.apply(recipe.steps, to: input) }
      let text = try await withTaskCancellationHandler {
        try await worker.value
      } onCancel: {
        worker.cancel()
      }
      try Task.checkCancellation()
      switch recipe.destination {
      case .copy: try executor.copy(text)
      case .paste: try await executor.paste(text, snapshot: snapshot, restore: true)
      case .note:
        try await executor.send(
          executor.makeDraft(snapshot, kind: .note, text: text, target: recipe.targetNoteID))
      }
    }
  }
  private func allowsWorkflow(_ id: String) -> Bool {
    LayoutTree.enabledEntries(library.layout).contains {
      $0.provider == "app.popclip.builtin." + id
    }
  }
  private func runWorkflow(
    _ title: String, snapshot: SelectionSnapshot,
    operation: @escaping @MainActor (SelectionExecutor) async throws -> Void
  ) {
    guard !busy else { return }
    busy = true
    operationID += 1
    let invocation = operationID
    dismissBar?()
    showBusy?(snapshot)
    actionTask = Task { [self] in
      do { try await operation(executor) } catch {
        if operationID == invocation { reportFailure(error, title: title, snapshot: snapshot) }
      }
      if operationID == invocation {
        busy = false
        hideBusy?()
      }
    }
  }
  func execute(
    _ action: ExtensionAction, record: ExtensionRecord, snapshot: SelectionSnapshot,
    moduleAction: Int? = nil, modulePath: [Int]? = nil, openSubmenu: Bool = false
  ) {
    guard !busy else { return }
    if let id = record.instanceID,
      !LayoutTree.enabledEntries(library.layout).contains(where: { $0.id == id })
    {
      return
    }
    if action.kind == "submenu" {
      openStaticSubmenu(action, record: record, snapshot: snapshot)
      return
    }
    busy = true
    dismissBar?()
    showBusy?(snapshot)
    operationID += 1
    let operation = operationID
    notice = ""
    let invocationModifiers = UInt64(NSEvent.modifierFlags.rawValue)
    actionTask = Task { [self] in
      var openedSettings = false
      do {
        var record = record
        if let expires = try OwnSecrets.read(record: record, option: "authExpires").flatMap(
          Double.init), expires < Date().timeIntervalSince1970
        {
          try OwnSecrets.write("", extensionID: record.secretIdentifier)
        }
        if let secret = try OwnSecrets.read(record: record) {
          record.options["authsecret"] = .string(secret)
        }
        for option in record.config["options"]?.array ?? [] {
          let d = option.object
          let id = d["identifier"]?.string ?? ""
          if d["type"]?.string == "secret",
            let secret = try OwnSecrets.read(record: record, option: id)
          {
            record.options[id] = .string(secret)
          }
        }
        var context = snapshot.context
        if action.config["capturehtml"]?.bool == true || action.config["capturertf"]?.bool == true {
          context = try await executor.captureRich(snapshot)
        }
        context.modifierFlags = invocationModifiers
        guard operationID == operation else { return }
        let matched =
          action.kind == "module"
          ? context
          : ActionMatcher.match(action, context: context, options: record.effectiveOptions)
        guard let matched
        else {
          busy = false
          hideBusy?()
          return
        }
        executor.onShow = { [weak self] in self?.showResult?($0, $1) }
        executor.onLargeText = { [weak self] in self?.showLargeText?($0) }
        executor.onSettings = { [weak self] in
          openedSettings = true
          self?.selectedExtension = record.instanceID ?? record.id
          self?.showSettings?()
        }
        executor.onAppear = { [weak self] in self?.reappear?() }
        let response = try await executor.run(
          action, record: record, context: matched, snapshot: snapshot, moduleAction: moduleAction,
          modulePath: modulePath, openSubmenu: openSubmenu)
        guard operationID == operation else { return }
        if let error = response.error { throw LibraryError.invalid(error) }
        if action.kind == "module", response.didExecute != true {
          if modulePath == nil, moduleAction == nil, response.actions.count == 1,
            let only = response.actions.first, only["disabled"]?.bool != true,
            only["separator"]?.bool != true
          {
            var captured = action
            captured.config["capturehtml"] = only["captureHtml"] ?? .bool(false)
            captured.config["capturertf"] = only["captureRtf"] ?? .bool(false)
            busy = false
            execute(
              captured, record: record, snapshot: snapshot,
              modulePath: only["path"]?.array.compactMap { Int($0.string) },
              openSubmenu: only["submenu"]?.bool == true && only["hasCode"]?.bool != true)
            return
          }
          showActions?(response.actions, record, snapshot)
        } else {
          try await executor.apply(
            response.effects, snapshot: snapshot,
            onShow: { [weak self] in self?.showResult?($0, $1) },
            onSettings: { [weak self] in
              openedSettings = true
              self?.selectedExtension = record.instanceID ?? record.id
              self?.showSettings?()
            }, onAppear: { [weak self] in self?.reappear?() })
          if action.kind != "module", let output = response.result, output != .null {
            try await executor.after(
              action.config["after"]?.string ?? "", result: output.string, snapshot: snapshot,
              restore: action.config["restorepasteboard"]?.bool == true,
              onShow: { [weak self] in self?.showResult?($0, $1) })
          }
          if action.kind != "module", action.config["stayvisible"]?.bool == true { reappear?() }
        }
      } catch {
        guard operationID == operation else { return }
        notice = error.localizedDescription
        if !openedSettings {
          reportFailure(error, title: action.title, snapshot: snapshot, record: record)
        }
      }
      if operationID == operation {
        busy = false
        hideBusy?()
      }
    }
  }
  func openStaticSubmenu(
    _ action: ExtensionAction, record: ExtensionRecord, snapshot: SelectionSnapshot
  ) {
    guard !busy else { return }
    var nested = record
    let options = ExtensionOptions.effective(
      record.config["options"]?.array ?? [], stored: record.options)
    nested.actions = ActionCatalog.children(
      of: action, name: record.name, context: snapshot.context, options: options)
    showActions?(staticMetadata(nested.actions, record: nested), nested, snapshot)
  }
  private func reportFailure(
    _ error: Error, title: String, snapshot: SelectionSnapshot, record: ExtensionRecord? = nil
  ) {
    guard !(error is CancellationError) else { return }
    let failure = ActionFailure(
      title: title, message: error.localizedDescription, instanceID: record?.instanceID,
      missingApplications: record == nil ? [] : executor.missingApplications)
    notice = failure.title + "：" + String(failure.message.prefix(400))
    if let showFailure {
      showFailure(failure, snapshot)
    } else {
      showResult?(failure.message, false)
    }
  }
  private func staticMetadata(_ actions: [ExtensionAction], record: ExtensionRecord) -> [[String:
    Value]]
  {
    actions.enumerated().map { index, action in
      let properties = action.config
      return [
        "index": .number(Double(index)), "title": .string(action.title), "static": .bool(true),
        "separator": .bool(action.kind == "separator"),
        "icon": properties["icon"] ?? .null, "iconProperties": .object(properties),
        "wantsPrimaryDisplay": properties["wantsprimarydisplay"] ?? .bool(false),
      ]
    }
  }
}

struct BuiltInAction {
  let id: String
  init(_ provider: String) { id = provider.components(separatedBy: ".").last ?? provider }
  var title: String {
    BuiltInCatalog.action(id)?.title ?? id
  }
  var symbol: String {
    BuiltInCatalog.action(id)?.symbol ?? "bolt"
  }
  @MainActor func visible(_ context: ActionContext) -> Bool {
    switch id {
    case "cut": return context.editable && !context.text.isEmpty
    case "paste", "plainpaste":
      return context.editable && NSPasteboard.general.availableType(from: [.string]) != nil
    case "openlink": return !context.urls.isEmpty
    case "openmail": return !ActionMatcher.emails(context.text).isEmpty
    case "revealfile": return !ActionMatcher.paths(context.text).isEmpty
    case "spelling": return false  // Supplied by the generation-scoped spelling controller.
    case "googletranslate", "navermap":
      return !context.text.isEmpty && context.text.utf8.prefix(8001).count <= 8000
    default: return !context.text.isEmpty
    }
  }
}
