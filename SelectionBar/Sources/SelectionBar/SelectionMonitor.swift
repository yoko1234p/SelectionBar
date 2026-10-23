import AppKit
import ApplicationServices
import SelectionBarCore

@MainActor
struct SelectionSnapshot {
  var context: ActionContext
  var application: NSRunningApplication
  var element: AXUIElement
  var range: CFRange?
  var anchor: CGRect
  var capturedAt: Date
  var lease: SelectionLease
  var localEditor: NSTextView? = nil
  var pointer: CGPoint? = nil
  var browserLease: BrowserSelectionLease? = nil
}

@MainActor
final class SelectionLease {
  private var expected: SelectionIntegrity
  init(element: AXUIElement, text: String, range: CFRange?) {
    expected = SelectionIntegrity(
      text: text, range: range.map { NSRange(location: $0.location, length: $0.length) },
      value: AX.read(element, kAXValueAttribute) as? String)
  }
  init(editor: NSTextView) {
    let range = editor.selectedRange()
    expected = SelectionIntegrity(
      text: (editor.string as NSString).substring(with: range),
      range: range, value: editor.string)
  }
  func validate(_ element: AXUIElement, editor: NSTextView? = nil) -> Bool {
    if let editor {
      let range = editor.selectedRange()
      return expected.matches(
        text: (editor.string as NSString).substring(with: range), range: range, value: editor.string
      )
    }
    return expected.matches(
      text: AX.read(element, kAXSelectedTextAttribute) as? String, range: AX.range(element),
      value: AX.read(element, kAXValueAttribute) as? String)
  }
  func refreshAfterOwnEdit(_ element: AXUIElement, editor: NSTextView? = nil) {
    if let editor {
      let range = editor.selectedRange()
      expected = SelectionIntegrity(
        text: (editor.string as NSString).substring(with: range), range: range, value: editor.string
      )
      return
    }
    guard let text = AX.read(element, kAXSelectedTextAttribute) as? String else { return }
    expected = SelectionIntegrity(
      text: text, range: AX.range(element), value: AX.read(element, kAXValueAttribute) as? String)
  }
}

@MainActor
final class SelectionMonitor {
  private let model: SelectionModel
  private let onSelection: (SelectionSnapshot) -> Void
  private var global: Any?
  private var pending: DispatchWorkItem?
  private var observers: [NSObjectProtocol] = []
  private var mouseDown: NSPoint?
  private var lastSignature: Int?
  private let browser = BrowserIntegration()
  private var captureTask: Task<Void, Never>?
  init(model: SelectionModel, onSelection: @escaping (SelectionSnapshot) -> Void) {
    self.model = model
    self.onSelection = onSelection
    for name in [
      NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
      NSWorkspace.didActivateApplicationNotification,
    ] {
      observers.append(
        NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main)
        { [weak self] _ in Task { @MainActor in self?.refresh() } })
    }
  }
  func refresh() {
    model.refreshStatus()
    stopMonitor()
    // Activation, permission and settings changes invalidate the old source
    // selection even when no further mouse event arrives to dismiss the bar.
    model.dismissBar?()
    guard model.storageError == nil, model.library.settings.enabled, model.permission,
      !model.conflict
    else { return }
    global = NSEvent.addGlobalMonitorForEvents(matching: [
      .leftMouseDown, .leftMouseUp, .keyUp, .scrollWheel,
    ]) { [weak self] event in
      Task { @MainActor in
        guard let self else { return }
        switch event.type {
        case .leftMouseDown:
          self.lastSignature = nil
          self.mouseDown = NSEvent.mouseLocation
          self.model.dismissBar?()
        case .leftMouseUp:
          let point = NSEvent.mouseLocation
          let dragged = self.mouseDown.map { hypot($0.x - point.x, $0.y - point.y) > 3 } ?? false
          if dragged || event.clickCount >= 2 { self.schedule() } else { self.model.dismissBar?() }
        case .keyUp:
          if let combo = try? KeyCombo.parse(self.model.library.settings.hotkey),
            event.keyCode == combo.code,
            event.modifierFlags.rawValue & 0x1e0000 == combo.flags & 0x1e0000
          {
            self.capture(force: true)
          } else if event.modifierFlags.contains(.shift),
            [123, 124, 125, 126].contains(event.keyCode)
          {
            self.schedule()
          } else if event.keyCode == 53 {
            self.model.dismissBar?()
          }
        case .scrollWheel: self.model.dismissBar?()
        default: break
        }
      }
    }
  }
  private func schedule() {
    pending?.cancel()
    let item = DispatchWorkItem { [weak self] in self?.capture() }
    pending = item
    DispatchQueue.main.asyncAfter(deadline: .now() + model.library.settings.delay, execute: item)
  }
  func capture(force: Bool = false) {
    guard model.storageError == nil else { return }
    model.refreshStatus()
    guard model.permission || force, model.library.settings.enabled || force, !model.conflict else {
      return
    }
    guard let app = NSWorkspace.shared.frontmostApplication,
      app.bundleIdentifier != Bundle.main.bundleIdentifier
    else { return }
    let settings = model.library.settings
    let listed = settings.excludedApps.contains(app.bundleIdentifier ?? "")
    guard force || (settings.includedAppsOnly ? listed : !listed) else { return }
    captureTask?.cancel()
    browser.cancel()
    captureTask = Task { [weak self] in
      guard let self else { return }
      do {
        var captured: SelectionSnapshot?
        do { captured = try Self.snapshot(app: app) } catch {
          if error.localizedDescription.contains("密碼") { throw error }
        }
        let id = app.bundleIdentifier ?? ""
        var page: BrowserSelection?
        if settings.browserIntegration, let family = BrowserBridge.family(id), family != .basic,
          captured?.context.text.isEmpty != false || captured?.context.browserURL.isEmpty != false
        {
          page = try? await browser.read(
            id, selection: captured?.context.text.isEmpty != false, allowPrompt: force)
        }
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        else { return }
        if captured == nil, page != nil {
          let element = AXUIElementCreateApplication(app.processIdentifier)
          let point = NSEvent.mouseLocation
          captured = SelectionSnapshot(
            context: ActionContext(
              text: "", bundleIdentifier: id,
              appName: app.localizedName ?? ""), application: app, element: element, range: nil,
            anchor: CGRect(x: point.x, y: point.y, width: 1, height: 1), capturedAt: Date(),
            lease: SelectionLease(element: element, text: "", range: nil), pointer: point)
        }
        guard var snapshot = captured else {
          throw LibraryError.invalid(L10n.text("此 App 未提供可讀取的文字選區。"))
        }
        if let page {
          snapshot.context.browserURL = page.url
          snapshot.context.browserTitle = page.title
          if snapshot.context.text.isEmpty, !page.text.isEmpty || page.editable {
            snapshot.context.text = page.text
            snapshot.context.matchedText = page.text
            snapshot.context.html = page.html
            snapshot.context.editable = page.editable
            snapshot.context.formatting = page.editable && !page.html.isEmpty
            snapshot.browserLease = BrowserSelectionLease(page, browserID: id)
          }
        }
        guard force || !snapshot.context.text.isEmpty else { return }
        guard
          force || !WebsiteRules.excludes(snapshot.context.browserURL, rules: settings.websiteRules)
        else { return }
        // Dedupe only needs a process-local fingerprint. Retaining the entire
        // selection here kept up to 2 MB of private text after the bar closed.
        var fingerprint = Hasher()
        fingerprint.combine(app.processIdentifier)
        fingerprint.combine(snapshot.range?.location)
        fingerprint.combine(snapshot.range?.length)
        fingerprint.combine(snapshot.context.text)
        let signature = fingerprint.finalize()
        if force || lastSignature != signature {
          lastSignature = signature
          model.selection = snapshot
          onSelection(snapshot)
        }
      } catch { if force && !Task.isCancelled { model.notice = error.localizedDescription } }
    }
  }
  static func snapshot(app: NSRunningApplication) throws -> SelectionSnapshot {
    let application = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(application, 0.3)
    guard let element = AX.read(application, kAXFocusedUIElementAttribute) else {
      throw LibraryError.invalid(L10n.text("此 App 未提供可讀取的文字選區。"))
    }
    let focused = unsafeBitCast(element, to: AXUIElement.self)
    let role = AX.string(focused, kAXRoleAttribute)
    let subrole = AX.string(focused, kAXSubroleAttribute)
    guard !role.lowercased().contains("secure"), !subrole.lowercased().contains("secure") else {
      throw LibraryError.invalid(L10n.text("密碼欄位不顯示操作列。"))
    }
    let text = AX.string(focused, kAXSelectedTextAttribute)
    guard text.utf8.count <= 2 * 1024 * 1024 else {
      throw LibraryError.invalid(L10n.text("選區大於 2 MB，請縮小選區。"))
    }
    var range: CFRange?
    if let value = AX.read(focused, kAXSelectedTextRangeAttribute),
      CFGetTypeID(value) == AXValueGetTypeID()
    {
      var r = CFRange()
      if AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &r) { range = r }
    }
    var isSettable: DarwinBoolean = false
    AXUIElementIsAttributeSettable(focused, kAXSelectedTextAttribute as CFString, &isSettable)
    let editable =
      isSettable.boolValue || [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
    var anchor = CGRect(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y, width: 1, height: 1)
    if var range, let value = AXValueCreate(.cfRange, &range) {
      var bounds: CFTypeRef?
      if AXUIElementCopyParameterizedAttributeValue(
        focused, kAXBoundsForRangeParameterizedAttribute as CFString, value, &bounds) == .success,
        let bounds, CFGetTypeID(bounds) == AXValueGetTypeID()
      {
        var rect = CGRect.zero
        if AXValueGetValue(unsafeBitCast(bounds, to: AXValue.self), .cgRect, &rect), rect.width > 0,
          rect.height > 0
        {
          let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
          anchor = CGRect(
            x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
        }
      }
    }
    var browserURL = ""
    var browserTitle = ""
    if let raw = AX.read(application, kAXFocusedWindowAttribute) {
      browserURL = AX.string(unsafeBitCast(raw, to: AXUIElement.self), kAXDocumentAttribute)
      browserTitle = AX.string(unsafeBitCast(raw, to: AXUIElement.self), kAXTitleAttribute)
    }
    let context = ActionContext(
      text: text, bundleIdentifier: app.bundleIdentifier ?? "", appName: app.localizedName ?? "",
      editable: editable, formatting: role == kAXTextAreaRole, browserURL: browserURL,
      browserTitle: browserTitle,
      modifierFlags: UInt64(NSEvent.modifierFlags.rawValue))
    return SelectionSnapshot(
      context: context, application: app, element: focused, range: range, anchor: anchor,
      capturedAt: Date(), lease: SelectionLease(element: focused, text: text, range: range),
      pointer: NSEvent.mouseLocation)
  }
  private func stopMonitor() {
    lastSignature = nil
    if let global {
      NSEvent.removeMonitor(global)
      self.global = nil
    }
    pending?.cancel()
    pending = nil
    captureTask?.cancel()
    captureTask = nil
    browser.cancel()
  }
  func stop() {
    stopMonitor()
    for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    observers = []
  }
}

enum AX {
  static func range(_ element: AXUIElement) -> NSRange? {
    guard let value = read(element, kAXSelectedTextRangeAttribute),
      CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    var range = CFRange()
    guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range) else {
      return nil
    }
    return NSRange(location: range.location, length: range.length)
  }
  static func read(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
      ? value : nil
  }
  static func string(_ element: AXUIElement, _ attribute: String) -> String {
    read(element, attribute) as? String ?? ""
  }
}
