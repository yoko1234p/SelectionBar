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
  var insertionOnly = false
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
  private var eventTap: CFMachPort?
  private var eventSource: CFRunLoopSource?
  private var fallback: Any?
  private var inputGeneration: UInt64 = 0
  private var inputFilter = SelectionInputFilter()
  private(set) var pending: DispatchWorkItem?
  private var observers: [NSObjectProtocol] = []
  private let workspace: NotificationCenter
  private var mouseDown: NSPoint?
  private var lastSignature: Int?
  private let browser = BrowserIntegration()
  private var captureTask: Task<Void, Never>?
  private var captureGeneration = UUID()
  init(
    model: SelectionModel, workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
    onSelection: @escaping (SelectionSnapshot) -> Void
  ) {
    self.model = model
    self.workspace = workspace
    self.onSelection = onSelection
    for name in [
      NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
      NSWorkspace.didActivateApplicationNotification,
      NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
      NSWorkspace.sessionDidBecomeActiveNotification,
      NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
      NSWorkspace.sessionDidResignActiveNotification,
    ] {
      observers.append(
        workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] notice in
          MainActor.assumeIsolated {
            let app = notice.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.workspaceChanged(notice.name, applicationID: app?.bundleIdentifier)
          }
        })
    }
  }
  func workspaceChanged(_ name: Notification.Name, applicationID: String? = nil) {
    if name == NSWorkspace.didLaunchApplicationNotification
      || name == NSWorkspace.didTerminateApplicationNotification
    {
      // Background workers are unrelated to the active selection. Only PopClip
      // changes the conflict policy; its launch/exit must still refresh hooks.
      guard SelectionModel.conflictingApplications.contains(applicationID ?? "") else { return }
    }
    if [
      NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
      NSWorkspace.sessionDidResignActiveNotification,
    ].contains(name) {
      stopMonitor()
      mouseDown = nil
      model.dismissBar?()
    } else {
      refresh()
    }
  }
  func refresh() {
    model.refreshStatus()
    SelectionDiagnostics.record(
      "refresh permission=\(model.permission) enabled=\(model.library.settings.enabled) conflict=\(model.conflict)"
    )
    stopMonitor()
    // Activation, permission and settings changes invalidate the old source
    // selection even when no further mouse event arrives to dismiss the bar.
    model.dismissBar?()
    guard model.storageError == nil, model.library.settings.enabled, model.permission,
      !model.conflict
    else { return }
    installInputMonitor()
  }
  private func installInputMonitor() {
    let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .keyDown, .keyUp, .scrollWheel]
    let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    let context = Unmanaged.passUnretained(self).toOpaque()
    if let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
      eventsOfInterest: mask,
      callback: { _, type, event, context in
        if let context {
          MainActor.assumeIsolated {
            Unmanaged<SelectionMonitor>.fromOpaque(context).takeUnretainedValue()
              .receivedTap(type, event: event)
          }
        }
        // This is an observer: never modify, suppress or replace user input.
        return Unmanaged.passUnretained(event)
      }, userInfo: context),
      let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    {
      eventTap = tap
      eventSource = source
      CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
      CGEvent.tapEnable(tap: tap, enable: true)
      SelectionDiagnostics.record("input tap installed")
      return
    }
    // Preserve the previous monitoring path if macOS refuses an event tap.
    SelectionDiagnostics.record("input tap unavailable; using AppKit monitor")
    fallback = NSEvent.addGlobalMonitorForEvents(matching: [
      .leftMouseDown, .leftMouseUp, .keyDown, .keyUp, .scrollWheel,
    ]) { [weak self] event in
      MainActor.assumeIsolated { self?.handle(event, pointer: NSEvent.mouseLocation) }
    }
  }
  private func receivedTap(_ type: CGEventType, event: CGEvent) {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      SelectionDiagnostics.record("input tap disabled type=\(type.rawValue)")
      if let eventTap, AXIsProcessTrusted() {
        CGEvent.tapEnable(tap: eventTap, enable: true)
      } else {
        let generation = inputGeneration
        DispatchQueue.main.async { [weak self] in
          guard let self, self.inputGeneration == generation else { return }
          self.refresh()
        }
      }
      return
    }
    // Trackpad scrolling can emit many events per second. Nothing needs to be
    // dismissed until a selection or overlay exists.
    if type == .scrollWheel, model.selection == nil, model.overlayFrame?() == nil { return }
    if type == .keyDown, mouseDown == nil, pending == nil, captureTask == nil,
      model.selection == nil, model.overlayFrame?() == nil { return }
    guard let event = NSEvent(cgEvent: event) else { return }
    let quartz = event.cgEvent?.location ?? .zero
    let top = NSScreen.screens.first?.frame.maxY ?? 0
    let pointer = CGPoint(x: quartz.x, y: top - quartz.y)
    if type == .keyDown || type == .keyUp {
      // AppKit's global monitor never observed key events in SelectionBar itself.
      guard !NSApp.isActive else { return }
    } else {
      let activeFrames = NSApp.isActive ? NSApp.windows.filter(\.isVisible).map(\.frame) : []
      guard
        !inputFilter.ignoresMouse(
          type: type, pointer: pointer, overlay: model.overlayFrame?(), activeWindows: activeFrames)
      else {
        if type == .leftMouseDown { mouseDown = nil }
        return
      }
      if type == .leftMouseDown {
        // Activation can rebuild the tap before the queued callback runs.
        // Retain the drag origin so the first selection in another app works.
        mouseDown = pointer
      }
    }
    let generation = inputGeneration
    // The event-tap callback must return promptly. Snapshot the event position
    // now so fast drags are measured using their actual down/up coordinates.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.inputGeneration == generation else { return }
      self.handle(event, pointer: pointer)
    }
  }
  func handle(_ event: NSEvent, pointer: CGPoint) {
    switch event.type {
    case .leftMouseDown:
      SelectionDiagnostics.record("mouse-down")
      pending?.cancel()
      pending = nil
      captureTask?.cancel()
      captureTask = nil
      browser.cancel()
      self.lastSignature = nil
      self.mouseDown = pointer
      self.model.dismissBar?()
    case .leftMouseUp:
      let point = pointer
      let dragged = self.mouseDown.map { hypot($0.x - point.x, $0.y - point.y) > 3 } ?? false
      self.mouseDown = nil
      SelectionDiagnostics.record("mouse-up dragged=\(dragged) clicks=\(event.clickCount)")
      if dragged || event.clickCount >= 2 {
        self.schedule()
      } else {
        self.schedule(insertionPoint: point)
      }
    case .keyDown:
      // A click can schedule the insertion toolbar shortly before typing.
      // Cancel both scheduled and in-flight work so it cannot reappear later.
      pending?.cancel()
      pending = nil
      captureTask?.cancel()
      captureTask = nil
      browser.cancel()
      if model.selection != nil || model.overlayFrame?() != nil { model.dismissBar?() }
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
  private func schedule(insertionPoint: CGPoint? = nil) {
    pending?.cancel()
    let item = DispatchWorkItem { [weak self] in
      self?.pending = nil
      self?.capture(insertionPoint: insertionPoint)
    }
    pending = item
    DispatchQueue.main.asyncAfter(deadline: .now() + model.library.settings.delay, execute: item)
  }
  func capture(force: Bool = false, insertionPoint: CGPoint? = nil) {
    SelectionDiagnostics.record("capture force=\(force)")
    guard model.storageError == nil else { return }
    model.refreshStatus()
    guard model.permission || force, model.library.settings.enabled || force, !model.conflict else {
      return
    }
    guard let app = NSWorkspace.shared.frontmostApplication,
      app.bundleIdentifier != Bundle.main.bundleIdentifier
    else { return }
    let settings = model.library.settings
    SelectionDiagnostics.record("source=\(app.bundleIdentifier ?? "unknown")")
    let listed = settings.excludedApps.contains(app.bundleIdentifier ?? "")
    guard force || (settings.includedAppsOnly ? listed : !listed) else { return }
    if insertionPoint != nil {
      let insertion = ActionContext(text: "", editable: true)
      guard
        LayoutTree.enabledEntries(model.library.layout).contains(where: {
          ["paste", "plainpaste"].contains(BuiltInAction($0.provider).id)
            && model.library.record(for: $0) == nil
            && BuiltInAction($0.provider).visible(insertion)
        })
      else { return }
    }
    captureTask?.cancel()
    browser.cancel()
    let generation = UUID()
    captureGeneration = generation
    captureTask = Task { [weak self] in
      guard let self else { return }
      defer { if self.captureGeneration == generation { self.captureTask = nil } }
      do {
        var captured: SelectionSnapshot?
        do { captured = try Self.snapshot(app: app, insertionPoint: insertionPoint) } catch {
          SelectionDiagnostics.record("AX snapshot failed")
          if error.localizedDescription.contains("密碼") { throw error }
        }
        if insertionPoint != nil {
          guard let captured, captured.context.editable, captured.context.text.isEmpty else {
            return
          }
        }
        let id = app.bundleIdentifier ?? ""
        SelectionDiagnostics.record("AX selected-count=\(captured?.context.text.count ?? -1)")
        var page: BrowserSelection?
        if insertionPoint == nil, settings.browserIntegration, let family = BrowserBridge.family(id),
          family != .basic,
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
        // Never bypass configured website exclusions when a browser does not
        // expose its current URL through Accessibility for a simple click.
        if insertionPoint != nil,
          !Self.allowsInsertion(appID: id, url: snapshot.context.browserURL, rules: settings.websiteRules)
        {
          return
        }
        guard force || !snapshot.context.text.isEmpty || insertionPoint != nil else { return }
        guard
          force || !WebsiteRules.excludes(snapshot.context.browserURL, rules: settings.websiteRules)
        else { return }
        snapshot.insertionOnly = insertionPoint != nil
        if let point = insertionPoint {
          snapshot.anchor = CGRect(x: point.x, y: point.y, width: 1, height: 1)
        }
        // Dedupe only needs a process-local fingerprint. Retaining the entire
        // selection here kept up to 2 MB of private text after the bar closed.
        var fingerprint = Hasher()
        fingerprint.combine(app.processIdentifier)
        fingerprint.combine(snapshot.range?.location)
        fingerprint.combine(snapshot.range?.length)
        fingerprint.combine(snapshot.context.text)
        let signature = fingerprint.finalize()
        if force || lastSignature != signature {
          SelectionDiagnostics.record("present count=\(snapshot.context.text.count)")
          lastSignature = signature
          model.selection = snapshot
          onSelection(snapshot)
        }
      } catch { if force && !Task.isCancelled { model.notice = error.localizedDescription } }
    }
  }
  static func allowsInsertion(appID: String, url: String, rules: [WebsiteRule]) -> Bool {
    if BrowserBridge.family(appID) != nil, rules.contains(where: \.enabled), url.isEmpty {
      return false
    }
    return !WebsiteRules.excludes(url, rules: rules)
  }
  private static func isEditableHit(_ focused: AXUIElement, point: CGPoint) -> Bool {
    var selectedTextSettable: DarwinBoolean = false
    var valueSettable: DarwinBoolean = false
    AXUIElementIsAttributeSettable(
      focused, kAXSelectedTextAttribute as CFString, &selectedTextSettable)
    AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &valueSettable)
    guard selectedTextSettable.boolValue || valueSettable.boolValue else { return false }
    let system = AXUIElementCreateSystemWide()
    let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
    var hit: AXUIElement?
    guard
      AXUIElementCopyElementAtPosition(system, Float(point.x), Float(primaryTop - point.y), &hit)
        == .success
    else { return false }
    // The hit may be a child of a text view; never accept an unrelated element
    // simply because the previous text field retained keyboard focus.
    for _ in 0..<12 {
      guard let element = hit else { break }
      if CFEqual(element, focused) { return true }
      guard let parent = AX.read(element, kAXParentAttribute),
        CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
      hit = unsafeBitCast(parent, to: AXUIElement.self)
    }
    return false
  }
  static func snapshot(app: NSRunningApplication, insertionPoint: CGPoint? = nil) throws
    -> SelectionSnapshot
  {
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
    if let insertionPoint, !isEditableHit(focused, point: insertionPoint) {
      throw LibraryError.invalid(L10n.text("此 App 未提供可讀取的文字選區。"))
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
    inputGeneration &+= 1
    inputFilter = SelectionInputFilter()
    if let eventTap {
      CGEvent.tapEnable(tap: eventTap, enable: false)
      CFMachPortInvalidate(eventTap)
      self.eventTap = nil
    }
    if let eventSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), eventSource, .commonModes)
      self.eventSource = nil
    }
    if let fallback {
      NSEvent.removeMonitor(fallback)
      self.fallback = nil
    }
    pending?.cancel()
    pending = nil
    captureTask?.cancel()
    captureTask = nil
    captureGeneration = UUID()
    browser.cancel()
  }
  func stop() {
    stopMonitor()
    for observer in observers { workspace.removeObserver(observer) }
    observers = []
  }
}

/// Global Core Graphics taps include this application's events, unlike AppKit's
/// global monitor. Do not dismiss a toolbar while its own buttons are clicked.
struct SelectionInputFilter {
  private var ignoredMouseDown = false
  mutating func ignoresMouse(
    type: CGEventType, pointer: CGPoint, overlay: CGRect?, activeWindows: [CGRect]
  ) -> Bool {
    let ownWindow =
      overlay?.contains(pointer) == true || activeWindows.contains { $0.contains(pointer) }
    switch type {
    case .leftMouseDown:
      ignoredMouseDown = ownWindow
      return ownWindow
    case .leftMouseUp:
      let ignored = ignoredMouseDown || ownWindow
      ignoredMouseDown = false
      return ignored
    default:
      return ownWindow
    }
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
