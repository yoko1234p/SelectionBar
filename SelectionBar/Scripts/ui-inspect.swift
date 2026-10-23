import AppKit
import ApplicationServices
import Foundation

func read(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
  var value: CFTypeRef?
  return AXUIElementCopyAttributeValue(e, key as CFString, &value) == .success ? value : nil
}
func children(_ e: AXUIElement, _ depth: Int = 0) -> [AXUIElement] {
  guard depth < 16 else { return [] }
  var values = read(e, kAXChildrenAttribute) as? [AXUIElement] ?? []
  if let menu = read(e, "AXShownMenuUIElement"), CFGetTypeID(menu) == AXUIElementGetTypeID() {
    values.append(unsafeBitCast(menu, to: AXUIElement.self))
  }
  return [e] + values.prefix(250).flatMap { children($0, depth + 1) }
}
func data(_ e: AXUIElement) -> [String: Any] {
  var d: [String: Any] = [:]
  for key in [
    kAXRoleAttribute, kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
    kAXHelpAttribute,
  ] { if let value = read(e, key) as? String { d[key] = value } }
  var point = CGPoint.zero
  var size = CGSize.zero
  if let raw = read(e, kAXPositionAttribute), CFGetTypeID(raw) == AXValueGetTypeID(),
    AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgPoint, &point)
  {
    d["x"] = point.x
    d["y"] = point.y
  }
  if let raw = read(e, kAXSizeAttribute), CFGetTypeID(raw) == AXValueGetTypeID(),
    AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgSize, &size)
  {
    d["w"] = size.width
    d["h"] = size.height
  }
  return d
}
func emit(_ object: Any) {
  let data = try! JSONSerialization.data(
    withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
  print(String(decoding: data, as: UTF8.self))
}
let args = CommandLine.arguments
let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
guard (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue != true, args.count >= 3,
  let pid = Int32(args[2]), let app = NSRunningApplication(processIdentifier: pid),
  ["com.pilotmoon.popclip-setapp", "com.pilotmoon.popclip", "local.pakwingho.selectionbar"]
    .contains(app.bundleIdentifier ?? ""), AXIsProcessTrusted()
else {
  fputs("Target/desktop/AX guard failed\n", stderr)
  exit(2)
}
let application = AXUIElementCreateApplication(pid)
let windows = read(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
let extras = read(application, kAXExtrasMenuBarAttribute).map {
  unsafeBitCast($0, to: AXUIElement.self)
}
let nodes = windows.flatMap { children($0) } + (extras.map { children($0) } ?? [])
func fixtureOnly() {
  guard app.bundleIdentifier == "local.pakwingho.selectionbar",
    windows.contains(where: {
      read($0, kAXTitleAttribute) as? String == "SelectionBar · Synthetic Editor"
    })
  else {
    fputs("An owned synthetic editor is required\n", stderr)
    exit(5)
  }
}
func matching(_ node: AXUIElement, _ target: String) -> Bool {
  [kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].contains {
    read(node, $0) as? String == target
  }
}
switch args[1] {
case "dump": emit(nodes.map(data))
case "activate": app.activate(options: [])
case "focused":
  fixtureOnly()
  var value: [String: Any] = [
    "frontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
    "postingAllowed": CGPreflightPostEventAccess(),
  ]
  if let raw = read(application, kAXFocusedWindowAttribute) {
    value["window"] = data(unsafeBitCast(raw, to: AXUIElement.self))
  }
  if let raw = read(application, kAXFocusedUIElementAttribute) {
    value["element"] = data(unsafeBitCast(raw, to: AXUIElement.self))
  }
  emit(value)
case "mouse-hover", "mouse-left", "mouse-right", "mouse-double":
  fixtureOnly()
  guard args.count == 4, CGPreflightPostEventAccess(),
    let target = nodes.first(where: { matching($0, args[3]) }),
    let x = data(target)["x"] as? CGFloat, let y = data(target)["y"] as? CGFloat,
    let width = data(target)["w"] as? CGFloat, let height = data(target)["h"] as? CGFloat,
    width > 0, height > 0
  else { exit(4) }
  let point = CGPoint(x: x + min(width / 2, 80), y: y + min(height / 2, 18))
  var hit: AXUIElement?
  guard
    AXUIElementCopyElementAtPosition(
      AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
    let hit
  else { exit(6) }
  var hitPID: pid_t = 0
  guard AXUIElementGetPid(hit, &hitPID) == .success, hitPID == pid,
    children(target).contains(where: { CFEqual($0, hit) })
  else { exit(6) }
  CGEvent(
    mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
    .post(tap: .cghidEventTap)
  if args[1] != "mouse-hover" {
    Thread.sleep(forTimeInterval: 0.04)
    let right = args[1] == "mouse-right"
    for click in 1...(args[1] == "mouse-double" ? 2 : 1) {
      for down in [true, false] {
        let type: CGEventType =
          right ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .leftMouseDown : .leftMouseUp)
        let event = CGEvent(
          mouseEventSource: nil, mouseType: type, mouseCursorPosition: point,
          mouseButton: right ? .right : .left)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
        event?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)
      }
    }
  }
  emit(["posted": true, "targetPID": pid, "x": point.x, "y": point.y])
case "selected-length":
  fixtureOnly()
  guard args.count == 4, args[3] == "selectionbar.failure.details",
    let target = nodes.first(where: { matching($0, args[3]) })
  else { exit(4) }
  let text = read(target, kAXSelectedTextAttribute) as? String ?? ""
  emit(["selectedUTF16Length": text.utf16.count])
case "focus-settings", "focus-editor":
  fixtureOnly()
  guard
    let window = windows.first(where: {
      read($0, kAXTitleAttribute) as? String
        == (args[1] == "focus-editor" ? "SelectionBar · Synthetic Editor" : "SelectionBar")
    })
  else { exit(4) }
  app.activate(options: [])
  _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
  emit(["result": AXUIElementPerformAction(window, kAXRaiseAction as CFString).rawValue])
case "set":
  fixtureOnly()
  guard args.count == 5 else { exit(4) }
  let scope =
    args[3] == "sheet-field"
    ? nodes.first(where: { read($0, kAXRoleAttribute) as? String == "AXSheet" }).map {
      children($0)
    } ?? [] : nodes
  let fields = scope.filter {
    [kAXTextFieldRole, kAXTextAreaRole].contains(read($0, kAXRoleAttribute) as? String ?? "")
      && (args[3] == "sheet-field" || matching($0, args[3]))
  }
  guard fields.count == 1, let target = fields.first
  else { exit(4) }
  emit([
    "result": AXUIElementSetAttributeValue(
      target, kAXValueAttribute as CFString, args[4] as CFString
    ).rawValue
  ])
case "key", "session-key":
  fixtureOnly()
  guard args.count == 5, let code = UInt16(args[3]), let flags = UInt64(args[4]),
    let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
    let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
  else { exit(4) }
  down.flags = CGEventFlags(rawValue: flags)
  up.flags = down.flags
  if args[1] == "session-key" {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
      let focused = read(application, kAXFocusedUIElementAttribute),
      read(unsafeBitCast(focused, to: AXUIElement.self), kAXIdentifierAttribute) as? String
        == "selectionbar.shortcut-recorder"
    else { exit(5) }
    down.post(tap: .cgSessionEventTap)
    up.post(tap: .cgSessionEventTap)
  } else {
    down.postToPid(pid)
    up.postToPid(pid)
  }
case "row-menu":
  fixtureOnly()
  guard args.count == 4,
    let menu = nodes.first(where: {
      matching($0, args[3]) && read($0, kAXRoleAttribute) as? String == "AXMenuButton"
    })
  else { exit(4) }
  emit(["result": AXUIElementPerformAction(menu, kAXPressAction as CFString).rawValue])
case "close":
  guard
    let window = windows.first(where: {
      ["PopClip", "SelectionBar"].contains(read($0, kAXTitleAttribute) as? String ?? "")
    }), let raw = read(window, kAXCloseButtonAttribute)
  else { exit(4) }
  emit([
    "result": AXUIElementPerformAction(
      unsafeBitCast(raw, to: AXUIElement.self), kAXPressAction as CFString
    ).rawValue
  ])
case "status":
  guard
    let item = (extras.map { children($0) } ?? []).first(where: {
      read($0, kAXRoleAttribute) as? String == kAXMenuBarItemRole
    })
  else { exit(3) }
  emit(["result": AXUIElementPerformAction(item, kAXPressAction as CFString).rawValue])
case "press":
  let allowed: Set<String> = [
    "Preferences…", "Settings…", "偏好設定…", "設定…", "Appearance", "Actions", "Extensions", "General",
    "Excluded Apps", "外觀", "動作", "擴充功能", "一般", "排除的 App", "App…", "App", "關閉",
  ]
  guard args.count == 4,
    app.bundleIdentifier == "local.pakwingho.selectionbar" || allowed.contains(args[3]),
    let target = nodes.first(where: { node in
      matching(node, args[3])
    })
  else { exit(4) }
  emit(["result": AXUIElementPerformAction(target, kAXPressAction as CFString).rawValue])
case "windows":
  let list =
    (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []).filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
  emit(
    list.map {
      [
        "id": $0[kCGWindowNumber as String] ?? 0, "bounds": $0[kCGWindowBounds as String] ?? [:],
        "title": $0[kCGWindowName as String] ?? "",
      ]
    })
default: exit(1)
}
