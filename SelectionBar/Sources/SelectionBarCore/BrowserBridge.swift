import AppKit
import Carbon
import Foundation

public struct BrowserSelection: Codable, Equatable, Sendable {
  public var url: String
  public var title: String
  public var text: String
  public var html: String
  public var editable: Bool
  public var signature: String
  public init(payload: [String: Value], window: String, tab: String) throws {
    guard payload["secure"]?.bool != true else {
      throw LibraryError.invalid(L10n.text("密碼欄位不顯示操作列。"))
    }
    url = payload["url"]?.string ?? ""
    title = payload["title"]?.string ?? ""
    text = payload["text"]?.string ?? ""
    html = payload["html"]?.string ?? ""
    editable = payload["editable"]?.bool ?? false
    guard text.utf8.count <= 2 * 1024 * 1024, html.utf8.count <= 2 * 1024 * 1024 else {
      throw LibraryError.invalid(L10n.text("瀏覽器選區過大。"))
    }
    signature = Manifest.digest(
      try JSONEncoder().encode([
        window, tab, url, text, payload["identity"]?.string ?? "",
      ]))
  }
}

public enum BrowserBridge {
  public enum Family: String, Sendable { case safari, chromium, basic }
  public static let safariIDs: Set<String> = [
    "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.kagi.kagimacOS",
  ]
  public static let chromiumIDs: Set<String> = [
    "company.thebrowser.Browser", "com.brave.Browser", "com.brave.Browser.beta",
    "com.brave.Browser.nightly",
    "org.chromium.Chromium", "ai.perplexity.comet", "org.ecosia.browser", "com.google.Chrome",
    "com.google.Chrome.canary", "net.imput.helium", "com.microsoft.edgemac",
    "com.microsoft.edgemac.Beta",
    "com.microsoft.edgemac.Canary", "com.microsoft.edgemac.Dev", "com.operasoftware.Opera",
    "com.operasoftware.OperaNext", "com.operasoftware.OperaDeveloper", "com.operasoftware.OperaGX",
    "com.pushplaylabs.sidekick", "org.chromium.Thorium", "com.vivaldi.Vivaldi",
    "com.vivaldi.Vivaldi.snapshot",
  ]
  public static let basicIDs: Set<String> = [
    "com.openai.atlas", "com.devon-technologies.agent", "company.thebrowser.dia",
    "com.duckduckgo.macos.browser",
    "org.mozilla.librewolf", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
    "org.mozilla.nightly",
    "net.mullvad.mullvadbrowser", "com.quark.desktop", "org.torproject.torbrowser",
    "net.waterfox.waterfox", "app.zen-browser.zen",
  ]
  public static func family(_ id: String) -> Family? {
    safariIDs.contains(id)
      ? .safari : chromiumIDs.contains(id) ? .chromium : basicIDs.contains(id) ? .basic : nil
  }
  public static var selectionJavaScript: String {
    guard let url = Bundle.module.url(forResource: "browser-selection", withExtension: "js") else {
      return ""
    }
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
  }
  public static func run(_ object: [String: Any]) throws -> [String: Any] {
    guard let id = object["browser"] as? String, let family = family(id), family != .basic,
      let operation = object["operation"] as? String,
      ["read", "open", "authorize"].contains(operation)
    else { throw LibraryError.invalid(L10n.text("未支援的瀏覽器操作。")) }
    guard !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty else {
      return ["value": operation == "open" ? ["opened": false] : NSNull()]
    }
    let target = NSAppleEventDescriptor(bundleIdentifier: id)
    guard let address = target.aeDesc else { throw LibraryError.invalid(L10n.text("瀏覽器目標無效。")) }
    let prompt = operation != "read" || object["allowPrompt"] as? Bool == true
    let permission = AEDeterminePermissionToAutomateTarget(
      address, typeWildCard, typeWildCard, prompt)
    if operation == "authorize" { return ["value": ["authorized": permission == noErr]] }
    guard permission == noErr else {
      if !prompt { return ["value": NSNull()] }
      throw LibraryError.invalid(L10n.text("請在「系統設定 → 私隱與保安 → 自動化」允許 SelectionBar 控制此瀏覽器。"))
    }
    let window = try specifier(
      want: "cwin", form: AEKeyword(formAbsolutePosition), data: NSAppleEventDescriptor(int32: 1))
    let tab = try property(family == .safari ? "cTab" : "acTa", of: window)
    if operation == "open" {
      guard let address = object["url"] as? String, let url = URL(string: address),
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
      else {
        throw LibraryError.invalid(L10n.text("瀏覽器分頁需要有效的網頁網址。"))
      }
      let oldIndex = family == .chromium ? try? get("acTI", of: window, target: target) : nil
      let oldTab: NSAppleEventDescriptor?
      if family == .safari {
        let read = event("core", "getd", target: target)
        read.setParam(tab, forKeyword: AEKeyword(keyDirectObject))
        oldTab = try? send(read)
      } else {
        oldTab = nil
      }
      let insertion = NSAppleEventDescriptor.record()
      insertion.setDescriptor(tab, forKeyword: fourCC("kobj"))
      insertion.setDescriptor(
        NSAppleEventDescriptor(enumCode: OSType(kAEAfter)), forKeyword: fourCC("kpos"))
      guard let location = insertion.coerce(toDescriptorType: typeInsertionLoc) else {
        throw LibraryError.invalid("Cannot build browser tab insertion")
      }
      let properties = NSAppleEventDescriptor.record()
      properties.setDescriptor(
        NSAppleEventDescriptor(string: address),
        forKeyword: fourCC(family == .safari ? "pURL" : "URL "))
      let make = event("core", "crel", target: target)
      make.setParam(
        NSAppleEventDescriptor(typeCode: fourCC(family == .safari ? "bTab" : "CrTb")),
        forKeyword: AEKeyword(keyAEObjectClass))
      make.setParam(location, forKeyword: AEKeyword(keyAEInsertHere))
      make.setParam(properties, forKeyword: AEKeyword(keyAEPropData))
      guard let created = try? send(make) else { return ["value": ["opened": false]] }
      let background = object["background"] as? Bool ?? false
      if family == .safari {
        if background, let oldTab {
          _ = try set("cTab", of: window, value: oldTab, target: target)
        } else if !background {
          _ = try set("cTab", of: window, value: created, target: target)
        }
      } else if let oldIndex {
        _ = try set(
          "acTI", of: window,
          value: NSAppleEventDescriptor(int32: oldIndex.int32Value + (background ? 0 : 1)),
          target: target)
      }
      return ["value": ["opened": true]]
    }
    var payload: [String: Value] = [
      "url": .string(
        (try? get(family == .safari ? "pURL" : "URL ", of: tab, target: target).stringValue) ?? ""),
      "title": .string((try? get("pnam", of: tab, target: target).stringValue) ?? ""),
    ]
    let windowID = (try? get("ID  ", of: window, target: target).stringValue) ?? ""
    let tabID =
      (try? get(family == .safari ? "pidx" : "ID  ", of: tab, target: target).stringValue) ?? ""
    if object["captureSelection"] as? Bool == true {
      let request = javaScriptEvent(
        family: family, target: target, tab: tab, source: selectionJavaScript)
      if let raw = try? send(request).stringValue, raw.utf8.count <= 8 * 1024 * 1024,
        let dictionary = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
      {
        payload.merge(dictionary.mapValues(Value.init)) { _, new in new }
      }
    }
    let selection = try BrowserSelection(payload: payload, window: windowID, tab: tabID)
    let data = try JSONEncoder().encode(selection)
    return ["value": try JSONSerialization.jsonObject(with: data)]
  }
  static func javaScriptEvent(
    family: Family, target: NSAppleEventDescriptor,
    tab: NSAppleEventDescriptor, source: String
  ) -> NSAppleEventDescriptor {
    let request = event(
      family == .safari ? "sfri" : "CrSu", family == .safari ? "dojs" : "ExJa", target: target)
    request.setParam(
      family == .safari ? NSAppleEventDescriptor(string: source) : tab,
      forKeyword: AEKeyword(keyDirectObject))
    request.setParam(
      family == .safari ? tab : NSAppleEventDescriptor(string: source),
      forKeyword: fourCC(family == .safari ? "dcnm" : "JvSc"))
    return request
  }
  static func specifier(
    want: String, form: AEKeyword, data: NSAppleEventDescriptor,
    container: NSAppleEventDescriptor = .null()
  ) throws -> NSAppleEventDescriptor {
    let record = NSAppleEventDescriptor.record()
    record.setDescriptor(
      NSAppleEventDescriptor(typeCode: fourCC(want)), forKeyword: AEKeyword(keyAEDesiredClass))
    record.setDescriptor(
      NSAppleEventDescriptor(enumCode: OSType(form)), forKeyword: AEKeyword(keyAEKeyForm))
    record.setDescriptor(data, forKeyword: AEKeyword(keyAEKeyData))
    record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
    guard let result = record.coerce(toDescriptorType: typeObjectSpecifier) else {
      throw LibraryError.invalid("Invalid browser specifier")
    }
    return result
  }
  private static func property(_ key: String, of container: NSAppleEventDescriptor) throws
    -> NSAppleEventDescriptor
  {
    try specifier(
      want: "prop", form: AEKeyword(formPropertyID),
      data: NSAppleEventDescriptor(typeCode: fourCC(key)), container: container)
  }
  private static func get(
    _ key: String, of object: NSAppleEventDescriptor, target: NSAppleEventDescriptor
  ) throws -> NSAppleEventDescriptor {
    let request = event("core", "getd", target: target)
    request.setParam(try property(key, of: object), forKeyword: AEKeyword(keyDirectObject))
    return try send(request)
  }
  private static func set(
    _ key: String, of object: NSAppleEventDescriptor, value: NSAppleEventDescriptor,
    target: NSAppleEventDescriptor
  ) throws -> NSAppleEventDescriptor {
    let request = event("core", "setd", target: target)
    request.setParam(try property(key, of: object), forKeyword: AEKeyword(keyDirectObject))
    request.setParam(value, forKeyword: AEKeyword(keyAEData))
    return try send(request)
  }
  private static func event(_ suite: String, _ name: String, target: NSAppleEventDescriptor)
    -> NSAppleEventDescriptor
  {
    NSAppleEventDescriptor(
      eventClass: fourCC(suite), eventID: fourCC(name), targetDescriptor: target,
      returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
    )
  }
  private static func send(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
    guard let raw = event.aeDesc else { throw LibraryError.invalid("Invalid browser event") }
    var reply = AppleEvent()
    let status = AESendMessage(raw, &reply, AESendMode(kAEWaitReply | kAENeverInteract), 180)
    guard status == noErr else {
      throw LibraryError.invalid(L10n.text("瀏覽器回應錯誤 %1$@。", String(describing: status)))
    }
    let result = NSAppleEventDescriptor(aeDescNoCopy: &reply)
    let error = result.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value ?? 0
    guard error == 0 else {
      throw LibraryError.invalid(L10n.text("瀏覽器回應錯誤 %1$@。", String(describing: error)))
    }
    return result.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) ?? .null()
  }
  private static func fourCC(_ text: String) -> OSType {
    text.utf8.reduce(0) { ($0 << 8) | OSType($1) }
  }
}
