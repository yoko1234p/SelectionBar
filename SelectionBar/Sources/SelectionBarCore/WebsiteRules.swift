import Foundation

public struct WebsiteRule: Codable, Equatable, Identifiable, Sendable {
  public enum Kind: String, Codable, CaseIterable, Sendable { case domain, host, address }
  public var id: String
  public var pattern: String
  public var kind: Kind
  public var enabled: Bool
  public init(
    id: String = UUID().uuidString, pattern: String, kind: Kind = .domain, enabled: Bool = true
  ) {
    self.id = id
    self.pattern = pattern
    self.kind = kind
    self.enabled = enabled
  }
  public func validated() throws -> WebsiteRule {
    var rule = self
    rule.pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rule.pattern.isEmpty, rule.pattern.utf8.count <= 4096 else {
      throw LibraryError.invalid(L10n.text("請輸入有效的網站網域或網址。"))
    }
    if kind != .address {
      let candidate =
        rule.pattern.hasPrefix("*.") ? String(rule.pattern.dropFirst(2)) : rule.pattern
      guard !candidate.contains(where: { $0.isWhitespace }), !candidate.contains("/"),
        let host = URLComponents(string: "https://" + candidate)?.host, !host.isEmpty,
        host == candidate || host.lowercased() == candidate.lowercased()
      else { throw LibraryError.invalid(L10n.text("網域請只填 example.com，毋須 https:// 或路徑。")) }
      rule.pattern = rule.pattern.lowercased().trimmingCharacters(
        in: CharacterSet(charactersIn: "."))
    } else {
      let sample = rule.pattern.replacingOccurrences(of: "*", with: "sample")
      guard let url = URLComponents(string: sample),
        ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
        url.host?.isEmpty == false
      else { throw LibraryError.invalid(L10n.text("網址需要以 http:// 或 https:// 開始。")) }
    }
    return rule
  }
  public func matches(_ address: String) -> Bool {
    guard enabled, address.utf8.count <= 65536, let rule = try? validated(),
      let components = URLComponents(string: address),
      ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
      let host = components.host?.lowercased().trimmingCharacters(
        in: CharacterSet(charactersIn: "."))
    else { return false }
    if kind != .address {
      let onlySubdomains = rule.pattern.hasPrefix("*.")
      let domain = onlySubdomains ? String(rule.pattern.dropFirst(2)) : rule.pattern
      return (!onlySubdomains && host == domain)
        || (kind == .domain && host.hasSuffix("." + domain))
    }
    var marker = "selectionbarwildcard"
    while rule.pattern.contains(marker) { marker += "x" }
    guard
      let expected = URLComponents(
        string: rule.pattern.replacingOccurrences(of: "*", with: marker)),
      let expectedHost = expected.host?.lowercased()
    else { return false }
    let hostPattern = expectedHost.replacingOccurrences(of: marker, with: "*")
    let pathPattern = expected.percentEncodedPath.replacingOccurrences(of: marker, with: "*")
    if rule.pattern.contains("*") {
      return LinearGlob.matches(hostPattern + pathPattern, host + components.percentEncodedPath)
    }
    guard expectedHost == host else { return false }
    // Original PopWebUrlMatcher ignores scheme/query/port and uses a path
    // prefix, so an imported example.com/foo also matches /foobar over HTTP.
    return components.percentEncodedPath.hasPrefix(expected.percentEncodedPath)
  }
}

enum LinearGlob {
  /// Only '*' is special. Literal chunks use KMP and consume the input once,
  /// avoiding regex backtracking in a selection-triggered main-thread check.
  static func matches(_ pattern: String, _ text: String) -> Bool {
    guard pattern.contains("*") else { return pattern == text }
    let input = Array(text.utf8)
    var chunks = pattern.split(separator: "*", omittingEmptySubsequences: true).map {
      Array($0.utf8)
    }
    if chunks.isEmpty { return true }
    var offset = 0
    var end = input.count
    if pattern.first != "*" {
      let first = chunks.removeFirst()
      guard input.starts(with: first) else { return false }
      offset = first.count
    }
    if pattern.last != "*", let last = chunks.popLast() {
      guard input.suffix(last.count).elementsEqual(last) else { return false }
      end -= last.count
    }
    guard offset <= end else { return false }
    for chunk in chunks {
      var prefix = [Int](repeating: 0, count: chunk.count)
      var length = 0
      for index in 1..<chunk.count {
        while length > 0 && chunk[index] != chunk[length] { length = prefix[length - 1] }
        if chunk[index] == chunk[length] { length += 1 }
        prefix[index] = length
      }
      var matched = 0
      var found = false
      while offset < end {
        while matched > 0 && input[offset] != chunk[matched] { matched = prefix[matched - 1] }
        if input[offset] == chunk[matched] { matched += 1 }
        offset += 1
        if matched == chunk.count {
          found = true
          break
        }
      }
      if !found { return false }
    }
    return true
  }
}

public enum WebsiteRules {
  public static func excludes(_ address: String, rules: [WebsiteRule]) -> Bool {
    rules.contains { $0.matches(address) }
  }
  public static func imported(_ value: Any?) -> [WebsiteRule] {
    let raw: [Any]
    if let values = value as? [Any] {
      raw = values
    } else if let dictionary = value as? [String: Any] {
      raw = dictionary.map { ["pattern": $0.key, "enabled": $0.value] }
    } else {
      return []
    }
    return raw.enumerated().compactMap { index, item in
      let object = item as? [String: Any] ?? [:]
      guard
        let text = (item as? String) ?? object["domain"] as? String
          ?? object["address"] as? String ?? object["url"] as? String ?? object["pattern"]
          as? String
      else { return nil }
      let canonical = text.contains("://") ? text : "https://" + text
      guard let components = URLComponents(string: canonical), let host = components.host else {
        return nil
      }
      let ipv4 = host.range(of: #"^\d+\.\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
      let kind: WebsiteRule.Kind =
        components.path.isEmpty ? (host.contains(".") && !ipv4 ? .domain : .host) : .address
      let id =
        "import-website-"
        + String(Manifest.digest(Data((String(index) + ":" + text).utf8)).prefix(20))
      return try? WebsiteRule(
        id: id, pattern: kind == .address ? canonical : host, kind: kind,
        enabled: object["enabled"] as? Bool ?? true
      ).validated()
    }
  }
}
