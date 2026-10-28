import Foundation

public struct ActionContext: Codable, Equatable, Sendable {
  public var text: String
  public var matchedText: String
  public var html: String
  public var rawHTML: String
  public var rtf: String
  public var markdown: String
  public var bundleIdentifier: String
  public var appName: String
  public var browserURL: String
  public var browserTitle: String
  public var editable: Bool
  public var formatting: Bool
  public var modifierFlags: UInt64
  public var regexResult: [String]
  public init(
    text: String, bundleIdentifier: String = "", appName: String = "", editable: Bool = false,
    formatting: Bool = false, html: String = "", rawHTML: String = "", markdown: String = "",
    browserURL: String = "", browserTitle: String = "", modifierFlags: UInt64 = 0
  ) {
    self.text = text
    matchedText = text
    self.bundleIdentifier = bundleIdentifier
    self.appName = appName
    self.editable = editable
    self.formatting = formatting
    self.html = html
    self.rtf = ""
    self.rawHTML = rawHTML
    self.markdown = markdown.isEmpty ? text : markdown
    self.browserURL = browserURL
    self.browserTitle = browserTitle
    self.modifierFlags = modifierFlags
    regexResult = []
  }
  public var urls: [String] { ActionMatcher.webURLs(text) }
  public var inputObject: [String: Any] {
    let detected = ActionMatcher.detected(text)
    return [
      "text": text, "matchedText": matchedText, "html": html, "xhtml": html, "rtf": rtf,
      "rawHtml": rawHTML, "markdown": markdown, "regexResult": regexResult, "isEditable": editable,
      "isUrl": detected["isUrl"] ?? false, "data": detected["data"] ?? [:],
      "__ranges": detected["ranges"] ?? [:],
      "content": ["public.utf8-plain-text": text, "public.html": html, "public.rtf": rtf],
    ]
  }
  public var contextObject: [String: Any] {
    [
      "bundleIdentifier": bundleIdentifier, "appIdentifier": bundleIdentifier,
      "hasFormatting": formatting, "canPaste": editable, "canCopy": !text.isEmpty,
      "canCut": editable && !text.isEmpty, "appName": appName, "browserUrl": browserURL,
      "browserTitle": browserTitle,
    ]
  }
  public func variables(options: [String: Value], extensionID: String, actionID: String) -> [String:
    String]
  {
    var result = [
      "TEXT": matchedText, "FULL_TEXT": text, "HTML": html, "RAW_HTML": rawHTML,
      "MARKDOWN": markdown, "URLENCODED_TEXT": ActionMatcher.urlEncode(matchedText),
      "URLS": urls.joined(separator: "\n"), "MODIFIER_FLAGS": String(modifierFlags),
      "BUNDLE_IDENTIFIER": bundleIdentifier, "APP_NAME": appName, "BROWSER_TITLE": browserTitle,
      "BROWSER_URL": browserURL, "EXTENSION_IDENTIFIER": extensionID, "ACTION_IDENTIFIER": actionID,
    ]
    for (key, value) in options {
      result[
        "OPTION_"
          + key.uppercased().replacingOccurrences(
            of: "[^A-Z0-9]", with: "_", options: .regularExpression)] = value.string
    }
    return result
  }
}

public enum ActionMatcher {
  public static func detected(_ text: String) -> [String: Any] {
    var urls: [String] = []
    var other: [String] = []
    var urlRanges: [[String: Int]] = []
    var otherRanges: [[String: Int]] = []
    let matches =
      (try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue).matches(
        in: text, range: NSRange(text.startIndex..., in: text))) ?? []
    for match in matches {
      guard let url = match.url else { continue }
      let range = ["location": match.range.location, "length": match.range.length]
      if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
        let source = Range(match.range, in: text).map { String(text[$0]) } ?? ""
        urls.append(
          source.contains("://")
            ? url.absoluteString
            : url.absoluteString.replacingOccurrences(
              of: "^http://", with: "https://", options: .regularExpression))
        urlRanges.append(range)
      } else if url.scheme?.lowercased() != "mailto" {
        other.append(url.absoluteString)
        otherRanges.append(range)
      }
    }
    let emails = Self.emails(text)
    let paths = Self.paths(text)
    func ranges(_ values: [String]) -> [[String: Int]] {
      values.map { value in
        let range = (text as NSString).range(of: value)
        return [
          "location": range.location == NSNotFound ? 0 : range.location,
          "length": range.location == NSNotFound ? (text as NSString).length : range.length,
        ]
      }
    }
    let isURL =
      urlRanges.count == 1 && urls.count == 1
      && text.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count == urlRanges[0]["length"]
    return [
      "isUrl": isURL,
      "data": ["urls": urls, "nonHttpUrls": other, "emails": emails, "paths": paths],
      "ranges": [
        "urls": urlRanges, "nonHttpUrls": otherRanges, "emails": ranges(emails),
        "paths": ranges(paths),
      ],
    ]
  }
  public static func webURLs(_ text: String) -> [String] {
    ((detected(text)["data"] as? [String: Any])?["urls"] as? [String]) ?? []
  }
  public static func emails(_ text: String) -> [String] {
    guard text.contains("@") else { return [] }
    guard
      let regex = try? NSRegularExpression(
        pattern: "(?<![A-Z0-9._%+-])[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}",
        options: .caseInsensitive)
    else { return [] }
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
      Range($0.range, in: text).map { String(text[$0]) }
    }
  }
  public static func paths(_ text: String) -> [String] {
    let path = NSString(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
      .expandingTildeInPath
    guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { return [] }
    return [NSString(string: path).standardizingPath]
  }
  public static func match(
    _ action: ExtensionAction, context: ActionContext, options: [String: Value]
  ) -> ActionContext? {
    let config = action.config
    let options = ExtensionOptions.effective(config["options"]?.array ?? [], stored: options)
    if config["excludedapps"]?.array.contains(.string(context.bundleIdentifier)) == true {
      return nil
    }
    if let required = config["requiredapps"]?.array, !required.isEmpty,
      !required.contains(.string(context.bundleIdentifier))
    {
      return nil
    }
    var result = context
    let requirements = config["requirements"]?.array.map(\.string) ?? ["text"]
    for raw in requirements {
      let negate = raw.hasPrefix("!")
      let requirement = negate ? String(raw.dropFirst()) : raw
      var valid: Bool
      var narrowed: String?
      switch requirement {
      case "text", "copy": valid = !context.text.isEmpty
      case "cut": valid = !context.text.isEmpty && context.editable
      case "paste": valid = context.editable
      case "formatting": valid = context.formatting
      case "url":
        let urls = webURLs(context.text)
        valid = urls.count == 1
        narrowed = urls.first
      case "isurl":
        let urls = webURLs(context.text)
        valid =
          urls.count == 1
          && context.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(
            of: "https://", with: ""
          ).replacingOccurrences(of: "http://", with: "")
            == urls.first?.replacingOccurrences(of: "https://", with: "").replacingOccurrences(
              of: "http://", with: "")
        narrowed = urls.first
      case "urls": valid = !webURLs(context.text).isEmpty
      case "email":
        let values = emails(context.text)
        valid = values.count == 1
        narrowed = values.first
      case "emails": valid = !emails(context.text).isEmpty
      case "path":
        let values = paths(context.text)
        valid = values.count == 1
        narrowed = values.first
      default:
        if requirement.hasPrefix("option-"), let equal = requirement.firstIndex(of: "=") {
          valid =
            options[
              String(requirement[requirement.index(requirement.startIndex, offsetBy: 7)..<equal])]?
            .string == String(requirement[requirement.index(after: equal)...])
        } else {
          valid = false
        }
      }
      guard negate ? !valid : valid else { return nil }
      if !negate, let narrowed { result.matchedText = narrowed }
    }
    if let pattern = config["regex"]?.string, !pattern.isEmpty {
      guard let regex = try? NSRegularExpression(pattern: pattern),
        let match = regex.firstMatch(
          in: result.matchedText,
          range: NSRange(result.matchedText.startIndex..., in: result.matchedText)),
        let range = Range(match.range, in: result.matchedText)
      else { return nil }
      result.regexResult = (0..<match.numberOfRanges).map { i in
        Range(match.range(at: i), in: result.matchedText).map { String(result.matchedText[$0]) }
          ?? ""
      }
      result.matchedText = String(result.matchedText[range])
    }
    return result
  }
  public static func urlEncode(_ text: String, plus: Bool = false) -> String {
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    let result = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    return plus ? result.replacingOccurrences(of: "%20", with: "+") : result
  }
  public static func templateURL(
    _ template: String, text: String, options: [String: Value], clean: Bool = false,
    plus: Bool = false, verbatim: Bool = false
  ) -> String {
    var query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if clean {
      query = query.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
    if verbatim { query = "\"" + query + "\"" }
    var result = template.replacingOccurrences(of: "***", with: urlEncode(query, plus: plus))
      .replacingOccurrences(of: "{popclip text}", with: urlEncode(query, plus: plus))
    for (key, value) in options {
      result = result.replacingOccurrences(
        of: "{popclip option \(key)}", with: urlEncode(value.string, plus: plus))
    }
    return result
  }
  public static func substituteAppleScript(_ source: String, variables: [String: String]) -> String
  {
    var result = source
    for (key, value) in variables {
      let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
        of: "\"", with: "\\\""
      ).replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n")
      result = result.replacingOccurrences(
        of: "{popclip " + key.lowercased().replacingOccurrences(of: "_", with: " ") + "}",
        with: escaped)
    }
    return result
  }
}

public struct KeyCombo: Equatable, Sendable {
  public var code: UInt16
  public var flags: UInt64
  public static func parse(
    _ raw: String, additionalFlags: UInt64 = 0, useASCIILayout: Bool = false
  ) throws -> KeyCombo {
    let pieces = raw.lowercased().split(separator: " ").map(String.init)
    guard let key = pieces.last else { throw LibraryError.invalid(L10n.text("快捷鍵不可留空。")) }
    var flags = additionalFlags
    for modifier in pieces.dropLast() {
      switch modifier {
      case "command", "cmd": flags |= 1 << 20
      case "option", "opt", "alt": flags |= 1 << 19
      case "control", "ctrl": flags |= 1 << 18
      case "shift": flags |= 1 << 17
      case "numpad": flags |= 1 << 21
      default: throw LibraryError.invalid(L10n.text("未知快捷鍵修飾鍵：%1$@", String(describing: modifier)))
      }
    }
    if key.count == 1 {
      let resolved = useASCIILayout
        ? KeyboardLayout.resolveASCII(key)
        : KeyboardLayout.resolve(key, numericPad: flags & (1 << 21) != 0)
      guard let resolved else {
        throw LibraryError.invalid(L10n.text("目前鍵盤排列無法輸入此快捷鍵字元：%1$@", String(describing: key)))
      }
      return KeyCombo(code: resolved.code, flags: flags | resolved.flags)
    }
    let codes: [String: UInt16] = [
      "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
      "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
      "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
      "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
      "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
      "delete": 51, "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126, "home": 115,
      "end": 119, "pageup": 116, "pagedown": 121, "f1": 122, "f2": 120, "f3": 99, "f4": 118,
      "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
      "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
    ]
    guard let code = codes[key] ?? (key.hasPrefix("0x") ? UInt16(key.dropFirst(2), radix: 16) : nil)
    else { throw LibraryError.invalid(L10n.text("未知快捷鍵：%1$@", String(describing: key))) }
    return KeyCombo(code: code, flags: flags)
  }
}

public enum Placement {
  public static func frame(
    anchor: CGRect, size: CGSize, visible: CGRect, below: Bool,
    primaryOffset: CGFloat? = nil, pointerX: CGFloat? = nil
  ) -> CGRect {
    let width = min(size.width, visible.width - 12)
    let height = min(size.height, visible.height - 12)
    let aboveY = anchor.maxY + 9
    let belowY = anchor.minY - height - 9
    var y = below ? belowY : aboveY
    if y + height > visible.maxY { y = belowY }
    if y < visible.minY { y = aboveY }
    return CGRect(
      x: min(
        max((pointerX ?? anchor.midX) - (primaryOffset ?? width / 2), visible.minX + 6),
        visible.maxX - width - 6),
      y: min(max(y, visible.minY + 6), visible.maxY - height - 6), width: width, height: height)
  }
}
