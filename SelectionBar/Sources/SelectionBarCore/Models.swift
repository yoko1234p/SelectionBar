import CoreFoundation
import Foundation

public enum Value: Codable, Equatable, Hashable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case array([Value])
  case object([String: Value])
  case null
  public init(any: Any) {
    switch any {
    case let v as String: self = .string(v)
    case let v as NSNumber:
      self = CFGetTypeID(v) == CFBooleanGetTypeID() ? .bool(v.boolValue) : .number(v.doubleValue)
    case let v as [Any]: self = .array(v.map(Value.init))
    case let v as [String: Any]: self = .object(v.mapValues(Value.init))
    default: self = .null
    }
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let v = try? c.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? c.decode(Double.self) {
      self = .number(v)
    } else if let v = try? c.decode(String.self) {
      self = .string(v)
    } else if let v = try? c.decode([String: Value].self) {
      self = .object(v)
    } else {
      self = .array(try c.decode([Value].self))
    }
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .string(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .bool(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .object(let v): try c.encode(v)
    case .null: try c.encodeNil()
    }
  }
  public var string: String {
    switch self {
    case .string(let v): return v
    case .number(let v):
      return v.isFinite && v.rounded() == v && abs(v) < Double(Int64.max)
        ? String(Int64(v)) : String(v)
    case .bool(let v): return v ? "1" : "0"
    default: return ""
    }
  }
  public var bool: Bool {
    if case .bool(let v) = self { return v }
    return false
  }
  public var array: [Value] {
    if case .array(let v) = self { return v }
    return []
  }
  public var object: [String: Value] {
    if case .object(let v) = self { return v }
    return [:]
  }
  public var any: Any {
    switch self {
    case .string(let v): return v
    case .number(let v): return v
    case .bool(let v): return v
    case .array(let v): return v.map(\.any)
    case .object(let v): return v.mapValues(\.any)
    case .null: return NSNull()
    }
  }
}

public struct ExtensionAction: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var title: String
  public var config: [String: Value]
  public init(id: String, title: String, config: [String: Value]) {
    self.id = id
    self.title = title
    self.config = config
  }
  public var kind: String {
    if config["separator"]?.bool == true { return "separator" }
    for k in [
      "url", "keycombo", "keycombos", "servicename", "shortcutname", "shellscript",
      "shellscriptfile", "applescript", "applescriptfile", "javascript", "javascriptfile", "module",
    ] where config[k] != nil { return k }
    if config["submenu"] != nil { return "submenu" }
    return "unsupported"
  }
  public var hasSubmenu: Bool { config["submenu"] != nil }
}

public struct ExtensionRecord: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var packagePath: String
  public var digest: String
  public var config: [String: Value]
  public var actions: [ExtensionAction]
  public var options: [String: Value]
  public var warnings: [String]
  public var instanceID: String?
  public var legacySecretFallback: Bool?
  public var secretIdentifier: String { instanceID.map { id + "#instance#" + $0 } ?? id }
  public var effectiveOptions: [String: Value] {
    ExtensionOptions.effective(config["options"]?.array ?? [], stored: options)
  }
  public init(
    id: String, name: String, packagePath: String, digest: String, config: [String: Value],
    actions: [ExtensionAction], options: [String: Value] = [:], warnings: [String] = []
  ) {
    self.id = id
    self.name = name
    self.packagePath = packagePath
    self.digest = digest
    self.config = config
    self.actions = actions
    self.options = options
    self.warnings = warnings
    instanceID = nil
    legacySecretFallback = nil
  }
}

public struct LayoutEntry: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var provider: String
  public var name: String?
  public var enabled: Bool
  public var order: Double
  public var parent: String?
  public var presentation: Int
  public var kind: Int
  public var options: [String: Value]?
  public var legacySecretFallback: Bool?
  public var icon: Value?
  public var color: String?
  public var sourceEnabled: Bool?
  public var isGroup: Bool { kind == 0 || kind == 2 }
  public var isSeparator: Bool { kind == 3 }
  public init(
    id: String, provider: String, name: String? = nil, enabled: Bool = true, order: Double,
    parent: String? = nil, presentation: Int = 0, kind: Int = 1,
    options: [String: Value]? = nil, icon: Value? = nil, color: String? = nil
  ) {
    self.id = id
    self.provider = provider
    self.name = name
    self.enabled = enabled
    self.order = order
    self.parent = parent
    self.presentation = presentation
    self.kind = kind
    self.options = options
    self.icon = icon
    self.color = color
    legacySecretFallback = nil
    sourceEnabled = nil
  }
}

public struct Settings: Codable, Equatable, Sendable {
  public var enabled = true
  public var launchAtLogin = false
  public var appearance = "auto"
  public var size = 34.0
  public var placement = "above"
  public var delay = 0.13
  public var excludedApps: [String] = []
  public var hotkey = "control option space"
  public var importedRawPreferences: [String: Value] = [:]
  public var websiteRules: [WebsiteRule] = []
  public var browserIntegration = true
  public var includedAppsOnly = false
  public var spellingLanguages: [String] = []
  public var spellingShowFirst = true
  public init() {}
  private enum CodingKeys: String, CodingKey {
    case enabled, launchAtLogin, appearance, size, placement, delay, excludedApps, hotkey
    case importedRawPreferences, websiteRules, browserIntegration, includedAppsOnly
    case spellingLanguages, spellingShowFirst
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
    appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? "auto"
    size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 34
    placement = try c.decodeIfPresent(String.self, forKey: .placement) ?? "above"
    delay = try c.decodeIfPresent(Double.self, forKey: .delay) ?? 0.13
    excludedApps = try c.decodeIfPresent([String].self, forKey: .excludedApps) ?? []
    hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? "control option space"
    importedRawPreferences =
      try c.decodeIfPresent([String: Value].self, forKey: .importedRawPreferences) ?? [:]
    websiteRules = try c.decodeIfPresent([WebsiteRule].self, forKey: .websiteRules) ?? []
    browserIntegration = try c.decodeIfPresent(Bool.self, forKey: .browserIntegration) ?? true
    includedAppsOnly = try c.decodeIfPresent(Bool.self, forKey: .includedAppsOnly) ?? false
    spellingLanguages = Array(
      (try c.decodeIfPresent([String].self, forKey: .spellingLanguages) ?? []).prefix(2))
    spellingShowFirst = try c.decodeIfPresent(Bool.self, forKey: .spellingShowFirst) ?? true
  }
}

public struct Library: Codable, Equatable, Sendable {
  public var schema = 2
  public var settings = Settings()
  public var layout: [LayoutEntry] = []
  public var extensions: [ExtensionRecord] = []
  public var migrationFingerprint: String?
  public var migratedAt: Date?
  public var notes: [String] = []
  public init() {}
  public static var initial: Library {
    var v = Library()
    v.layout = [
      "spelling", "search", "openlink", "cut", "copy", "paste", "plainpaste", "lookup",
      "revealfile", "uppercase",
      "lowercase", "speak",
    ].enumerated().map {
      LayoutEntry(
        id: "builtin-\($0.element)", provider: "app.popclip.builtin.\($0.element)",
        order: Double($0.offset) * 1000)
    }
    return v
  }
}

public enum LibraryError: LocalizedError {
  case invalid(String)
  public var errorDescription: String? {
    if case .invalid(let s) = self { return s }
    return nil
  }
}
