import AVFoundation
import AppKit
import ApplicationServices
import CoreServices
import LocalWorkflowKit
import SelectionBarCore

@MainActor
final class SelectionExecutor {
  var workflowDirectory = WorkflowFiles.directory
  private lazy var speech = AVSpeechSynthesizer()
  private var session: ScriptSession?
  private var activity = UUID()
  private let auth = AuthCoordinator()
  private let sharing = SharingCoordinator()
  private let browser = BrowserIntegration()
  private(set) var missingApplications: [AssociatedApplication] = []
  var onShow: ((String, Bool) -> Void)?
  var onLargeText: ((String) -> Void)?
  var onSettings: (() -> Void)?
  var onAppear: (() -> Void)?
  func cancel() {
    activity = UUID()
    session?.cancel()
    session = nil
    auth.cancel()
    sharing.cancel()
    browser.cancel()
  }
  func authenticate(_ record: ExtensionRecord, username: String = "", password: String = "")
    async throws -> String
  {
    guard let action = record.actions.first else {
      throw LibraryError.invalid(L10n.text("擴充沒有動作。"))
    }
    let token = UUID()
    activity = token
    let redirect = try await auth.prepare(extensionID: record.id)
    defer { if activity == token { auth.cancel() } }
    let info: [String: Value] = [
      "redirect": .string(redirect), "name": .string(record.name), "identifier": .string(record.id),
      "username": .string(username), "password": .string(password),
    ]
    let request = ScriptRequest(
      record: record, action: action, context: ActionContext(text: ""), phase: "auth",
      authInfo: info)
    let helper = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent(
      "SelectionBarRuntime"
    ).path
    let running = ScriptSession(executable: helper)
    session = running
    defer { if session === running { session = nil } }
    let response = try await running.run(request) { [weak self] effect in
      guard let self else { throw CancellationError() }
      guard effect["type"]?.string == "oauth" else {
        throw LibraryError.invalid(L10n.text("登入期間不接受此文字動作。"))
      }
      return try await self.auth.flow(effect)
    }
    if let error = response.error { throw LibraryError.invalid(error) }
    guard activity == token else { throw CancellationError() }
    let value = response.result ?? .null
    let secret = value.object["secret"]?.string ?? value.string
    guard !secret.isEmpty else { throw LibraryError.invalid(L10n.text("擴充未回傳登入憑證。")) }
    let sync = record.config["authkeychain"]?.string != "local"
    try OwnSecrets.write(secret, extensionID: record.secretIdentifier, sync: sync)
    if let expires = value.object["expiresIn"].flatMap({ Double($0.string) }) {
      try OwnSecrets.write(
        String(Date().timeIntervalSince1970 + expires), extensionID: record.secretIdentifier,
        option: "authExpires", sync: sync)
    }
    return value.object["label"]?.string ?? L10n.text("已登入")
  }
  func authorizeBrowser(_ identifier: String) async throws -> Bool {
    try await browser.authorize(identifier)
  }
  private func validate(_ snapshot: SelectionSnapshot) async throws -> Bool {
    try Task.checkCancellation()
    if let lease = snapshot.browserLease { return try await lease.validate(using: browser) }
    if let editor = snapshot.localEditor {
      guard editor.window?.firstResponder === editor else { return false }
    } else {
      let application = AXUIElementCreateApplication(snapshot.application.processIdentifier)
      AXUIElementSetMessagingTimeout(application, 0.3)
      guard let focused = AX.read(application, kAXFocusedUIElementAttribute),
        CFGetTypeID(focused) == AXUIElementGetTypeID(), CFEqual(focused, snapshot.element)
      else { return false }
    }
    return snapshot.lease.validate(snapshot.element, editor: snapshot.localEditor)
  }
  private func refreshLease(_ snapshot: SelectionSnapshot) async throws {
    if let lease = snapshot.browserLease {
      try await lease.refresh(using: browser)
    } else {
      snapshot.lease.refreshAfterOwnEdit(snapshot.element, editor: snapshot.localEditor)
    }
  }
  func focus(_ snapshot: SelectionSnapshot) async throws {
    try Task.checkCancellation()
    guard !snapshot.application.isTerminated else {
      throw LibraryError.invalid(L10n.text("來源 App 已結束；文字未貼上。"))
    }
    guard try await validate(snapshot) else {
      throw LibraryError.invalid(L10n.text("原選區已改動，請重新選取文字。"))
    }
    snapshot.application.activate(options: [])
    if let editor = snapshot.localEditor { editor.window?.makeFirstResponder(editor) }
    try await Task.sleep(for: .milliseconds(80))
    if snapshot.localEditor == nil,
      NSWorkspace.shared.frontmostApplication?.processIdentifier
        != snapshot.application.processIdentifier
    {
      throw LibraryError.invalid(L10n.text("未能返回來源 App，文字未貼上。"))
    }
    guard try await validate(snapshot) else {
      throw LibraryError.invalid(L10n.text("原選區已改動，請重新選取文字。"))
    }
    // A nonactivating panel keeps the source selection. Never restore an old
    // range after the user has selected or edited something else.
  }
  func press(
    _ raw: String, snapshot: SelectionSnapshot, target: String = "app", additional: UInt64 = 0
  ) async throws {
    guard ["app", "session", "hid"].contains(target) else {
      throw LibraryError.invalid(L10n.text("未知按鍵目標。"))
    }
    let standardEdit = ["command x", "command c", "command v"].contains(raw.lowercased())
    let combo = try KeyCombo.parse(raw, additionalFlags: additional, useASCIILayout: standardEdit)
    try Task.checkCancellation()
    if target == "app", try await validate(snapshot) == false {
      throw LibraryError.invalid(L10n.text("原選區已改動，請重新選取文字。"))
    }
    if let editor = snapshot.localEditor {
      guard combo.flags & CGEventFlags.maskCommand.rawValue != 0 else {
        throw LibraryError.invalid(L10n.text("此預覽只接受標準編輯指令。"))
      }
      switch combo.code {
      case 8: editor.copy(nil)
      case 9: editor.paste(nil)
      case 7: editor.cut(nil)
      case 0: editor.selectAll(nil)
      default: throw LibraryError.invalid(L10n.text("此預覽只接受標準編輯指令。"))
      }
      snapshot.lease.refreshAfterOwnEdit(snapshot.element, editor: editor)
      return
    }
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: combo.code, keyDown: true),
      let up = CGEvent(keyboardEventSource: nil, virtualKey: combo.code, keyDown: false)
    else { throw LibraryError.invalid(L10n.text("無法建立快捷鍵事件。")) }
    down.flags = CGEventFlags(rawValue: combo.flags)
    up.flags = down.flags
    try Task.checkCancellation()
    if target == "app" {
      down.postToPid(snapshot.application.processIdentifier)
      up.postToPid(snapshot.application.processIdentifier)
    } else {
      let tap: CGEventTapLocation = target == "hid" ? .cghidEventTap : .cgSessionEventTap
      down.post(tap: tap)
      up.post(tap: tap)
    }
    try await Task.sleep(for: .milliseconds(30))
    try await refreshLease(snapshot)
  }
  func copy(_ text: String) throws {
    try Task.checkCancellation()
    NSPasteboard.general.clearContents()
    guard NSPasteboard.general.setString(text, forType: .string),
      NSPasteboard.general.string(forType: .string) == text
    else {
      throw LibraryError.invalid(L10n.text("剪貼簿未能確認文字寫入。"))
    }
  }
  func paste(_ text: String, snapshot: SelectionSnapshot, restore: Bool) async throws {
    if !snapshot.context.editable {
      try copy(text)
      return
    }
    let previous = try restore ? PasteboardSnapshot() : nil
    do { try await focus(snapshot) } catch is CancellationError { throw CancellationError() } catch
    {
      try copy(text)
      throw LibraryError.invalid(L10n.text("原選區已改動，結果已複製到剪貼簿。請重新選取後貼上。"))
    }
    try copy(text)
    let change = NSPasteboard.general.changeCount
    try await press("command v", snapshot: snapshot)
    if let previous {
      try await Task.sleep(for: .milliseconds(250))
      if NSPasteboard.general.changeCount == change {
        try previous.restoreChecked(expectedChangeCount: change)
      }
    }
  }
  func performBuiltin(
    _ action: BuiltInAction, snapshot: SelectionSnapshot, onResult: @escaping (String) -> Void
  ) async throws {
    switch action.id {
    case "copy": try copy(snapshot.context.text)
    case "cut":
      try await focus(snapshot)
      try await press("command x", snapshot: snapshot)
    case "paste":
      try await focus(snapshot)
      try await press("command v", snapshot: snapshot)
    case "plainpaste":
      if let text = NSPasteboard.general.string(forType: .string) {
        try await paste(text, snapshot: snapshot, restore: false)
      }
    case "uppercase":
      try await paste(snapshot.context.text.uppercased(), snapshot: snapshot, restore: false)
    case "lowercase":
      try await paste(snapshot.context.text.lowercased(), snapshot: snapshot, restore: false)
    case "alternatingcase":
      try await paste(
        BuiltInCatalog.alternatingCase(snapshot.context.text), snapshot: snapshot, restore: false)
    case "googletranslate", "navermap":
      let url = try BuiltInCatalog.webURL(for: action.id, text: snapshot.context.text)
      try await openURL(url.absoluteString, context: snapshot.context)
    case "search":
      let query = ActionMatcher.urlEncode(snapshot.context.text)
      try await openURL("https://www.google.com/search?q=" + query, context: snapshot.context)
    case "openlink":
      if let url = snapshot.context.urls.first { try await openURL(url, context: snapshot.context) }
    case "openmail":
      if let address = ActionMatcher.emails(snapshot.context.text).first {
        try await openURL("mailto:" + address, context: snapshot.context)
      }
    case "revealfile":
      let paths = ActionMatcher.paths(snapshot.context.text).map { URL(fileURLWithPath: $0) }
      NSWorkspace.shared.activateFileViewerSelecting(paths)
    case "lookup":
      let text = snapshot.context.text
      if let definition = DCSCopyTextDefinition(
        nil, text as CFString, CFRange(location: 0, length: (text as NSString).length))
      {
        onResult(definition.takeRetainedValue() as String)
      } else {
        onResult(L10n.text("未找到字典解釋。"))
      }
    case "speak":
      if speech.isSpeaking {
        speech.stopSpeaking(at: .immediate)
      } else {
        speech.speak(AVSpeechUtterance(string: snapshot.context.text))
      }
    default: throw LibraryError.invalid(L10n.text("未支援此內建動作：%1$@", String(describing: action.id)))
    }
  }
  func captureRich(_ snapshot: SelectionSnapshot) async throws -> ActionContext {
    let previous = try PasteboardSnapshot()
    try await focus(snapshot)
    let before = NSPasteboard.general.changeCount
    try await press("command c", snapshot: snapshot)
    for _ in 0..<20 {
      if NSPasteboard.general.changeCount != before { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let board = NSPasteboard.general
    guard
      let receipt = RichCopyReceipt(
        pasteboard: board, previousChangeCount: before, expectedText: snapshot.context.text)
    else {
      throw LibraryError.invalid(L10n.text("未能確認選字複製；沒有還原或覆寫剪貼簿。"))
    }
    var context = snapshot.context
    context.rtf = board.string(forType: .rtf) ?? ""
    let raw = board.string(forType: .html) ?? ""
    context.rawHTML = raw
    context.html = Self.cleanHTML(raw)
    if context.html.isEmpty, let rtf = board.data(forType: .rtf),
      let rich = try? NSAttributedString(
        data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
        documentAttributes: nil),
      let data = try? rich.data(
        from: NSRange(location: 0, length: rich.length),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
    {
      context.html = Self.cleanHTML(String(decoding: data, as: UTF8.self))
    }
    if context.html.isEmpty {
      context.html =
        "<p>" + Self.escapeHTML(context.text).replacingOccurrences(of: "\n", with: "<br>")
        + "</p>"
    }
    context.markdown = context.text
    guard receipt.isCurrent(on: board) else {
      throw LibraryError.invalid(L10n.text("剪貼簿正在改變；請再試一次。"))
    }
    try previous.restoreChecked(expectedChangeCount: receipt.changeCount)
    return context
  }
  static func escapeHTML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
  }
  static func cleanHTML(_ html: String) -> String {
    html.replacingOccurrences(
      of: "(?is)<(script|style|iframe|object|embed)[^>]*>.*?</\\1\\s*>", with: "",
      options: .regularExpression
    ).replacingOccurrences(
      of: "(?i)\\s(on[a-z]+|style)\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", with: "",
      options: .regularExpression
    ).replacingOccurrences(of: "(?i)javascript:", with: "", options: .regularExpression)
  }
  func run(
    _ action: ExtensionAction, record: ExtensionRecord, context: ActionContext,
    snapshot: SelectionSnapshot, moduleAction: Int?, modulePath: [Int]? = nil,
    openSubmenu: Bool = false
  ) async throws -> ScriptResponse {
    missingApplications = []
    if action.kind != "module" { try checkApplications(action.config) }
    if action.kind != "module", let before = action.config["before"]?.string, !before.isEmpty {
      try await after(
        before, result: context.text, snapshot: snapshot, restore: false, onShow: { _, _ in })
    }
    let options = ExtensionOptions.effective(
      record.config["options"]?.array ?? [], stored: record.options)
    let config = action.config
    switch action.kind {
    case "url":
      let url = ActionMatcher.templateURL(
        config["url"]?.string ?? "", text: context.matchedText, options: options,
        clean: config["cleanquery"]?.bool == true, plus: config["spacesasplus"]?.bool == true,
        verbatim: NSEvent.modifierFlags.contains(.option))
      try await openURL(
        url, context: context, backgroundTab: NSEvent.modifierFlags.contains(.shift))
      return ScriptResponse()
    case "keycombo", "keycombos":
      let sequences = config["keycombos"]?.array.map(\.string) ?? [config["keycombo"]?.string ?? ""]
      try await keySequence(
        sequences, snapshot: snapshot, target: config["keycombotarget"]?.string ?? "session")
      return ScriptResponse()
    case "servicename":
      try performService(
        config["servicename"]?.string ?? "",
        input: ["public.utf8-plain-text": context.matchedText, "public.html": context.html])
      return ScriptResponse()
    case "shortcutname":
      let name = config["shortcutname"]?.string ?? ""
      let result = try await shortcut(name, input: context.matchedText)
      return ScriptResponse(result: result)
    case "shellscript", "shellscriptfile", "applescript", "applescriptfile":
      var record = record
      record.options = options
      let request = try ClassicScripts.request(action, record: record, context: context)
      return try await runWorker(request, snapshot: snapshot)
    case "javascript", "javascriptfile", "module":
      return try await runWorker(
        ScriptRequest(
          record: record, action: action, context: context,
          phase: action.kind == "module"
            && (openSubmenu || (moduleAction == nil && (modulePath?.isEmpty != false)))
            ? "population" : "action",
          moduleAction: moduleAction, clipboard: PasteboardSnapshot.currentStrings,
          modulePath: modulePath, openSubmenu: openSubmenu), snapshot: snapshot)

    default: throw LibraryError.invalid(L10n.text("此擴充的動作類型尚未支援。"))
    }
  }
  private func runWorker(_ request: ScriptRequest, snapshot: SelectionSnapshot) async throws
    -> ScriptResponse
  {
    let helper =
      Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(
        "SelectionBarRuntime"
      ).path ?? ""
    let running = ScriptSession(executable: helper)
    session = running
    defer { if session === running { session = nil } }
    return try await running.run(request) { [weak self] effect in
      guard let self else { throw CancellationError() }
      return try await self.host(effect, snapshot: snapshot, record: request.record)
    }
  }
  private func host(_ effect: [String: Value], snapshot: SelectionSnapshot, record: ExtensionRecord)
    async throws -> Value
  {
    switch effect["type"]?.string {
    case "checkApps":
      try checkApplications(["apps": effect["apps"] ?? .array([])])
      return .null
    case "permission":
      let permissions = effect["permissions"]?.array.map(\.string) ?? []
      try await PermissionCoordinator.request(permissions)
      return .null
    case "clipboardRead": return .object(PasteboardSnapshot.currentStrings.mapValues(Value.string))
    case "share":
      try await sharing.perform(
        name: effect["name"]?.string ?? "", values: effect["items"]?.array ?? [])
      return .null
    case "signInRequired":
      try OwnSecrets.write("", extensionID: record.secretIdentifier)
      onSettings?()
      return .null
    case "step":
      if effect["step"]?.string == "popclip-appear" {
        onAppear?()
        return .null
      }
      try await after(
        effect["step"]?.string ?? "", result: effect["result"]?.string ?? "", snapshot: snapshot,
        restore: effect["restore"]?.bool == true, onShow: { [weak self] in self?.onShow?($0, $1) })
      return .null
    case "shortcut":
      if let input = effect["input"], case .string = input {
      } else if effect["input"] != nil {
        throw LibraryError.invalid("Shortcut input must be a string")
      }
      return try await shortcut(effect["name"]?.string ?? "", input: effect["input"]?.string)
    case "command":
      let command = effect["command"]?.string ?? ""
      guard ["cut", "copy", "paste"].contains(command) else {
        throw LibraryError.invalid("Unknown command")
      }
      let transform = effect["transform"]?.string ?? "none"
      guard ["none", "plain"].contains(transform) else {
        throw LibraryError.invalid("Unknown clipboard transform")
      }
      if command == "paste", transform == "plain",
        let text = NSPasteboard.general.string(forType: .string)
      {
        try copy(text)
      }
      let before = NSPasteboard.general.changeCount
      try await after(command, result: "", snapshot: snapshot, restore: false, onShow: { _, _ in })
      if command == "cut" || command == "copy" {
        for _ in 0..<30 {
          if NSPasteboard.general.changeCount != before { break }
          try await Task.sleep(for: .milliseconds(20))
        }
        guard NSPasteboard.general.changeCount != before else {
          throw LibraryError.invalid(L10n.text("來源 App 未確認複製／剪下。"))
        }
      }
      if effect["transform"]?.string == "plain",
        let text = NSPasteboard.general.string(forType: .string)
      {
        try copy(text)
      }
      return .object([
        "clipboard": .object(PasteboardSnapshot.currentStrings.mapValues(Value.string))
      ])
    default:
      try await apply(
        [effect], snapshot: snapshot, onShow: { [weak self] in self?.onShow?($0, $1) },
        onSettings: { [weak self] in self?.onSettings?() },
        onAppear: { [weak self] in self?.onAppear?() })
      return .null
    }
  }
  private func checkApplications(_ config: [String: Value]) throws {
    let missing = AssociatedApplications.missing(in: config) {
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
    }
    guard missing.isEmpty else {
      missingApplications = missing
      throw MissingApplicationsError(applications: missing)
    }
  }
  private func keySequence(_ sequences: [String], snapshot: SelectionSnapshot, target: String)
    async throws
  {
    for sequence in sequences {
      if sequence.hasPrefix("wait ") {
        guard let ms = Int(sequence.dropFirst(5)), (0...5000).contains(ms) else {
          throw LibraryError.invalid(L10n.text("等待時間需要 0–5000 ms。"))
        }
      } else {
        _ = try KeyCombo.parse(sequence)
      }
    }
    for sequence in sequences {
      if sequence.hasPrefix("wait ") {
        try await Task.sleep(for: .milliseconds(Int(sequence.dropFirst(5))!))
      } else {
        try await press(sequence, snapshot: snapshot, target: target)
      }
    }
  }
  func apply(
    _ effects: [[String: Value]], snapshot: SelectionSnapshot,
    onShow: @escaping (String, Bool) -> Void, onSettings: @escaping () -> Void,
    onAppear: @escaping () -> Void
  ) async throws {
    for effect in effects {
      switch effect["type"]?.string {
      case "copy": try copy(effect["text"]?.string ?? "")
      case "paste":
        try await paste(
          effect["text"]?.string ?? "", snapshot: snapshot, restore: effect["restore"]?.bool == true
        )
      case "copyContent", "pasteContent":
        let content = effect["content"]?.object ?? [:]
        guard !content.isEmpty,
          content.values.allSatisfy({
            if case .string = $0 { return true }
            return false
          })
        else {
          throw LibraryError.invalid(L10n.text("剪貼簿內容需要至少一個文字格式。"))
        }
        let previous = try effect["restore"]?.bool == true ? PasteboardSnapshot() : nil
        NSPasteboard.general.clearContents()
        for (type, value) in content {
          guard
            NSPasteboard.general.setString(value.string, forType: NSPasteboard.PasteboardType(type))
          else {
            throw LibraryError.invalid(L10n.text("剪貼簿未能確認內容寫入。"))
          }
        }
        let change = NSPasteboard.general.changeCount
        if effect["type"]?.string == "pasteContent", snapshot.context.editable {
          try await focus(snapshot)
          try await press("command v", snapshot: snapshot)
          try await Task.sleep(for: .milliseconds(250))
          if NSPasteboard.general.changeCount == change {
            try previous?.restoreChecked(expectedChangeCount: change)
          }
        }
      case "show":
        if effect["style"]?.string == "large" {
          onLargeText?(effect["text"]?.string ?? "")
        } else {
          onShow(effect["text"]?.string ?? "", effect["preview"]?.bool == true)
        }
      case "success": onShow("✓", false)
      case "failure": onShow("✕", false)
      case "settings": onSettings()
      case "appear": onAppear()
      case "command":
        try await after(
          effect["command"]?.string ?? "", result: "", snapshot: snapshot, restore: false,
          onShow: onShow)
      case "key":
        let raw = effect["key"]?.string ?? ""
        let numeric = (Double(raw)).map { "0x" + String(Int($0), radix: 16) }
        try await press(
          numeric ?? raw, snapshot: snapshot, target: effect["target"]?.string ?? "session",
          additional: UInt64(Double(effect["modifiers"]?.string ?? "0") ?? 0))
      case "keys":
        try await keySequence(
          effect["keys"]?.array.map(\.string) ?? [], snapshot: snapshot,
          target: effect["target"]?.string ?? "session")
      case "url":
        try await openURL(
          effect["url"]?.string ?? "", context: snapshot.context, app: effect["app"]?.string,
          activate: effect["activate"]?.bool ?? true,
          backgroundTab: effect["backgroundTab"]?.bool ?? false)
      case "service":
        if let content = effect["input"], case .object(let dictionary) = content {
          try performService(effect["name"]?.string ?? "", input: dictionary.mapValues(\.string))
        } else {
          try performService(
            effect["name"]?.string ?? "",
            input: ["public.utf8-plain-text": effect["input"]?.string ?? snapshot.context.text])
        }
      case "shortcut":
        _ = try await shortcut(
          effect["name"]?.string ?? "", input: effect["input"]?.string ?? snapshot.context.text)
      case "reveal":
        let path = NSString(string: effect["path"]?.string ?? "").expandingTildeInPath
        var directory = ObjCBool(false)
        guard path.hasPrefix("/"),
          FileManager.default.fileExists(atPath: path, isDirectory: &directory)
        else {
          throw LibraryError.invalid(L10n.text("檔案不存在。"))
        }
        let url = URL(fileURLWithPath: path)
        if directory.boolValue {
          guard NSWorkspace.shared.open(url) else {
            throw LibraryError.invalid(L10n.text("Finder 未能開啟資料夾。"))
          }
        } else {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        }
      default:
        throw LibraryError.invalid(
          L10n.text("未支援 JavaScript API 效果：%1$@", String(describing: effect["type"]?.string ?? "")))
      }
    }
  }
  func after(
    _ step: String, result: String, snapshot: SelectionSnapshot, restore: Bool,
    onShow: @escaping (String, Bool) -> Void
  ) async throws {
    switch step {
    case "copy-result": try copy(result)
    case "paste-result": try await paste(result, snapshot: snapshot, restore: restore)
    case "preview-result", "show-result":
      try copy(result)
      onShow(result, step == "preview-result")
    case "show-status": onShow("✓", false)
    case "cut", "copy", "paste":
      try await focus(snapshot)
      try await press(
        "command " + ["cut": "x", "copy": "c", "paste": "v"][step]!, snapshot: snapshot)
    case "paste-plain":
      if let text = NSPasteboard.general.string(forType: .string) {
        try await paste(text, snapshot: snapshot, restore: restore)
      }
    case "copy-selection": try copy(snapshot.context.text)
    case "": break
    default: break
    }
  }
  func openURL(
    _ text: String, context: ActionContext, app: String? = nil, activate: Bool = true,
    backgroundTab: Bool = false
  ) async throws {
    try Task.checkCancellation()
    guard let url = URL(string: text), url.scheme != nil else {
      throw LibraryError.invalid(L10n.text("無效 URL。"))
    }
    let isWeb = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    let target =
      app
      ?? (isWeb && BrowserBridge.family(context.bundleIdentifier) != nil
        ? context.bundleIdentifier : "")
    let application =
      target.isEmpty
      ? NSWorkspace.shared.urlForApplication(toOpen: url)
      : NSWorkspace.shared.urlForApplication(withBundleIdentifier: target)
    guard let application else { throw LibraryError.invalid(L10n.text("找不到可開啟此 URL 的 App。")) }
    let browserID = target.isEmpty ? Bundle(url: application)?.bundleIdentifier : target
    if isWeb, backgroundTab, let browserID, let family = BrowserBridge.family(browserID),
      family != .basic,
      try await browser.open(url.absoluteString, browser: browserID, background: true)
    {
      if activate {
        NSRunningApplication.runningApplications(withBundleIdentifier: browserID).first?.activate(
          options: [])
      }
      return
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = activate
    _ = try await NSWorkspace.shared.open(
      [url], withApplicationAt: application, configuration: configuration)
  }
  func performService(_ name: String, input: [String: String]) throws {
    try Task.checkCancellation()
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !input.isEmpty else {
      throw LibraryError.invalid(L10n.text("Service 名稱及輸入不可留空。"))
    }
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    for (type, value) in input where !value.isEmpty {
      board.setString(value, forType: NSPasteboard.PasteboardType(type))
    }
    guard NSPerformService(name, board) else {
      throw LibraryError.invalid(
        L10n.text("macOS Service「%1$@」未能執行。請檢查服務 App 同系統服務設定。", String(describing: name)))
    }
  }
  private func shortcut(_ name: String, input: String?) async throws -> Value {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw LibraryError.invalid(L10n.text("Shortcut 名稱不可留空。"))
    }
    var payload: [String: Value] = ["kind": .string("shortcut"), "name": .string(name)]
    if let input { payload["input"] = .string(input) }
    let literal = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
    let config: [String: Value] = [
      "javascript": .string("return (await __externalPromise(" + literal + ")).value;")
    ]
    let record = ExtensionRecord(
      id: "local.selectionbar.shortcut", name: "Shortcut", packagePath: PrivateStore.root.path,
      digest: "builtin", config: config, actions: [])
    let helper = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent(
      "SelectionBarRuntime"
    ).path
    let worker = ScriptSession(executable: helper)
    let response = try await worker.run(
      ScriptRequest(
        record: record, action: ExtensionAction(id: "0", title: "Shortcut", config: config),
        context: ActionContext(text: ""))
    ) { _ in throw LibraryError.invalid("Unexpected Shortcut host request") }
    if let error = response.error { throw LibraryError.invalid(error) }
    return response.result ?? .null
  }

}

struct RichCopyReceipt {
  let changeCount: Int
  init?(pasteboard: NSPasteboard, previousChangeCount: Int, expectedText: String) {
    let changeCount = pasteboard.changeCount
    guard changeCount != previousChangeCount,
      let copied = pasteboard.string(forType: .string),
      Self.normalized(copied) == Self.normalized(expectedText),
      pasteboard.changeCount == changeCount
    else { return nil }
    self.changeCount = changeCount
  }
  func isCurrent(on pasteboard: NSPasteboard) -> Bool { pasteboard.changeCount == changeCount }
  private static func normalized(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
  }
}

@MainActor
struct PasteboardSnapshot {
  var data: [[(NSPasteboard.PasteboardType, Data)]]
  private let pasteboard: NSPasteboard
  init(pasteboard: NSPasteboard = .general, maximumBytes: Int = 16 * 1024 * 1024) throws {
    self.pasteboard = pasteboard
    let change = pasteboard.changeCount
    let items = pasteboard.pasteboardItems ?? []
    guard items.count <= 64, items.reduce(0, { $0 + $1.types.count }) <= 128 else {
      throw LibraryError.invalid(L10n.text("剪貼簿格式太多，未能完整保留；未更改剪貼簿。"))
    }
    var total = 0
    data = []
    for item in items {
      var values: [(NSPasteboard.PasteboardType, Data)] = []
      for type in item.types {
        guard let value = item.data(forType: type), value.count <= maximumBytes - total else {
          throw LibraryError.invalid(L10n.text("剪貼簿超過 16 MB 或有未能讀取的格式；未更改剪貼簿。"))
        }
        total += value.count
        values.append((type, value))
      }
      data.append(values)
    }
    guard pasteboard.changeCount == change else {
      throw LibraryError.invalid(L10n.text("剪貼簿正在改變；請再試一次。"))
    }
  }
  var strings: [String: String] {
    Dictionary(
      data.flatMap { $0 }.compactMap { type, data in
        String(data: data, encoding: .utf8).map { (type.rawValue, $0) }
      }, uniquingKeysWith: { first, _ in first })
  }
  static var currentStrings: [String: String] {
    var result: [String: String] = [:]
    for type in [NSPasteboard.PasteboardType.string, .html, .rtf] {
      if let value = NSPasteboard.general.string(forType: type), value.utf8.count <= 8 * 1024 * 1024
      {
        result[type.rawValue] = value
      }
    }
    return result
  }
  func restoreChecked(expectedChangeCount: Int? = nil) throws {
    let items = data.map { values in
      let item = NSPasteboardItem()
      for (type, data) in values {
        guard item.setData(data, forType: type) else { return nil as NSPasteboardItem? }
      }
      return item
    }
    guard items.allSatisfy({ $0 != nil }) else {
      throw LibraryError.invalid(L10n.text("剪貼簿還原資料無效。"))
    }
    if let expectedChangeCount, pasteboard.changeCount != expectedChangeCount {
      throw LibraryError.invalid(L10n.text("剪貼簿正在改變；請再試一次。"))
    }
    pasteboard.clearContents()
    if !items.isEmpty, !pasteboard.writeObjects(items.compactMap { $0 }) {
      throw LibraryError.invalid(L10n.text("剪貼簿未能確認還原。"))
    }
    let restored = pasteboard.pasteboardItems ?? []
    guard restored.count == data.count else {
      throw LibraryError.invalid(L10n.text("剪貼簿還原項目數量不符。"))
    }
    for (index, values) in data.enumerated() {
      for (type, expected) in values where restored[index].data(forType: type) != expected {
        throw LibraryError.invalid(L10n.text("剪貼簿還原內容不符。"))
      }
    }
  }
  func restore() {
    let items = data.map { values in
      let item = NSPasteboardItem()
      for (type, data) in values { item.setData(data, forType: type) }
      return item
    }
    pasteboard.clearContents()
    pasteboard.writeObjects(items)
  }
}
