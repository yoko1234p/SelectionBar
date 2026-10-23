import CryptoKit
import Foundation
import Yams

public enum Manifest {
  public static func key(_ key: String) -> String {
    var words = key.replacingOccurrences(
      of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression
    )
    .lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    if words.first == "extension" || words.first == "option" { words.removeFirst() }
    let k = words.joined()
    return [
      "id": "identifier", "imagefile": "icon", "blockedapps": "excludedapps", "js": "javascript",
      "regular expression": "regex", "regularexpression": "regex",
      "requiredsoftwareversion": "popclipversion", "requiredosversion": "macosversion",
      "scriptinterpreter": "interpreter", "passhtml": "capturehtml", "lang": "language",
    ][k] ?? k
  }
  public static func normalized(_ d: [String: Any]) -> [String: Value] {
    let containers: Set<String> = [
      "actions", "action", "options", "app", "apps", "submenu", "applescriptcall",
    ]
    return Dictionary(
      d.map { raw, value in
        let canonical = key(raw)
        if containers.contains(canonical) {
          if let dictionary = value as? [String: Any] {
            return (canonical, .object(normalized(dictionary)))
          }
          if let array = value as? [[String: Any]] {
            return (canonical, .array(array.map { .object(normalized($0)) }))
          }
        }
        return (canonical, Value(any: value))
      }, uniquingKeysWith: { _, new in new })
  }
  public static func localized(_ value: Value?, fallback: String = "") -> String {
    guard let value else { return fallback }
    if case .string(let s) = value { return s }
    let d = value.object
    for language in Locale.preferredLanguages + ["zh-Hant", "en"] {
      let normal = language.lowercased().replacingOccurrences(of: "_", with: "-")
      if let match = d.first(where: {
        $0.key.lowercased().replacingOccurrences(of: " ", with: "-") == normal
      }) {
        return match.value.string
      }
      if let match = d.first(where: {
        normal.hasPrefix($0.key.lowercased().replacingOccurrences(of: " ", with: "-"))
      }) {
        return match.value.string
      }
    }
    return d["en"]?.string ?? d.values.first?.string ?? fallback
  }
  public static func confinedFile(_ relative: String, root: URL) throws -> URL {
    guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\"),
      !relative.split(separator: "/").contains("..")
    else { throw LibraryError.invalid(L10n.text("擴充檔案路徑超出套件。")) }
    let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
    let candidate = root.appendingPathComponent(relative).resolvingSymlinksInPath()
      .standardizedFileURL
    guard candidate.path.hasPrefix(canonicalRoot.path + "/") else {
      throw LibraryError.invalid(L10n.text("擴充檔案路徑超出套件。"))
    }
    return candidate
  }
  public static func parsePackage(_ root: URL) throws -> ExtensionRecord {
    let fm = FileManager.default
    guard root.pathExtension.lowercased() == "popclipext" else {
      throw LibraryError.invalid(L10n.text("請選擇 .popclipext 套件。"))
    }
    let preferred = [
      "Config.yaml", "Config.json", "Config.js", "Config.ts", "Config.applescript", "Config.plist",
      "Config",
    ]
    let others = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.lastPathComponent.hasPrefix("Config.") }.map(\.lastPathComponent).sorted()
    let candidates = preferred + others.filter { !preferred.contains($0) }
    guard
      let path = candidates.map({ root.appendingPathComponent($0) }).first(where: {
        fm.fileExists(atPath: $0.path)
      })
    else { throw LibraryError.invalid(L10n.text("套件缺少 Config 設定檔。")) }
    let configFile = try confinedFile(path.lastPathComponent, root: root)
    guard (try configFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 4 * 1024 * 1024
    else {
      throw LibraryError.invalid(L10n.text("Config 設定檔過大。"))
    }
    let data = try Data(contentsOf: configFile)
    guard data.count <= 4 * 1024 * 1024 else {
      throw LibraryError.invalid(L10n.text("Config 設定檔過大。"))
    }
    var config: [String: Value]
    if path.pathExtension == "plist" {
      guard
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
          as? [String: Any]
      else { throw LibraryError.invalid(L10n.text("無效 plist 設定。")) }
      config = normalized(object)
    } else if path.pathExtension == "json" {
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw LibraryError.invalid(L10n.text("無效 JSON 設定。"))
      }
      config = normalized(object)
    } else if path.pathExtension == "yaml" {
      guard
        let object = try Yams.load(yaml: String(decoding: data, as: UTF8.self)) as? [String: Any]
      else { throw LibraryError.invalid(L10n.text("無效 YAML 設定。")) }
      config = normalized(object)
    } else {
      config = try parseSnippet(
        String(decoding: data, as: UTF8.self), filename: path.lastPathComponent)
    }
    let name = localized(config["name"], fallback: root.deletingPathExtension().lastPathComponent)
    let identifier =
      config["identifier"]?.string ?? "selectionbar.import.\(digest(data).prefix(20))"
    let actionObjects =
      config["actions"]?.array.map(\.object) ?? config["action"].map { [$0.object] } ?? [[:]]
    let actions = actionObjects.enumerated().map { index, raw -> ExtensionAction in
      var action = config
      for (k, v) in raw { action[key(k)] = v }
      return ExtensionAction(
        id: action["identifier"]?.string ?? String(index),
        title: localized(action["title"], fallback: name), config: action)
    }
    var warnings: [String] = []
    if config["submenu"] != nil { warnings.append(L10n.text("submenu 以動作選單呈現。")) }
    if config["authservicelabel"] != nil {
      warnings.append(L10n.text("登入憑證不會從 PopClip 鑰匙圈讀取；需要重新登入。"))
    }
    if actions.contains(where: { $0.kind == "unsupported" }) {
      warnings.append(L10n.text("部分動作類型尚未支援。"))
    }
    return ExtensionRecord(
      id: identifier, name: name, packagePath: root.path, digest: try packageDigest(root),
      config: config, actions: actions, warnings: warnings)
  }
  public static func parseSnippet(_ text: String, filename: String = "Config.js") throws -> [String:
    Value]
  {
    let lines = text.components(separatedBy: .newlines)
    let first =
      lines.first { $0.trimmingCharacters(in: .whitespacesAndNewlines) != "" }?.trimmingCharacters(
        in: .whitespaces) ?? ""
    let shebang = first.hasPrefix("#!") ? first : nil
    let marker =
      lines.first { $0.lowercased().contains("#popclip") || $0.lowercased().contains("# popclip") }?
      .trimmingCharacters(in: .whitespaces) ?? first
    let prefix: String? =
      marker.hasPrefix("//")
      ? "//"
      : marker.hasPrefix("--") ? "--" : (marker.hasPrefix("# #") || shebang != nil) ? "#" : nil
    guard let prefix else {
      guard let object = try Yams.load(yaml: text) as? [String: Any] else {
        throw LibraryError.invalid(L10n.text("Snippet 缺少 YAML 設定。"))
      }
      return normalized(object)
    }
    var header: [String] = []
    var body: [String] = []
    var collecting = true
    for line in lines {
      let trim = line.trimmingCharacters(in: .whitespaces)
      if trim.hasPrefix("#!") && header.isEmpty { continue }
      if collecting, trim.hasPrefix(prefix) {
        var comment = String(trim.dropFirst(prefix.count))
        if comment.hasPrefix(" ") { comment.removeFirst() }
        header.append(comment)
        continue
      }
      if collecting, trim.isEmpty && header.isEmpty { continue }
      collecting = false
      body.append(line)
    }
    guard let object = try Yams.load(yaml: header.joined(separator: "\n")) as? [String: Any] else {
      throw LibraryError.invalid(L10n.text("Snippet 缺少 YAML 設定標頭。"))
    }
    var config = normalized(object)
    if config["interpreter"] != nil || shebang != nil || prefix == "#" {
      config["shellscriptfile"] = .string(filename)
      if config["interpreter"] == nil, let shebang {
        let interpreter = shebang.dropFirst(2).split(whereSeparator: \.isWhitespace).map(
          String.init)
        if interpreter.first == "/usr/bin/env", interpreter.count == 2 {
          config["interpreter"] = .string(interpreter[1])
        } else if interpreter.count == 1 {
          config["interpreter"] = .string(interpreter[0])
        }
      }
    } else if prefix == "--" {
      config["applescript"] = .string(body.joined(separator: "\n"))
    } else {
      config["__sourceextension"] = .string(
        config["language"]?.string == "javascript" ? "js" : "ts")
      if text.contains("defineExtension") || text.contains("export ") || text.contains("exports.")
        || text.contains("module.exports")
      {
        config["module"] = .string(filename)
      } else {
        config["javascript"] = .string(body.joined(separator: "\n"))
      }
    }
    return config
  }
  public static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  public static func packageDigest(_ root: URL) throws -> String {
    var hash = SHA256()
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    else { throw LibraryError.invalid(L10n.text("無法讀取套件。")) }
    let files = enumerator.compactMap { $0 as? URL }.sorted { $0.path < $1.path }
    guard files.count <= 10000 else { throw LibraryError.invalid(L10n.text("套件檔案過多。")) }
    var total = 0
    for file in files {
      let attributes = try file.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard attributes.isSymbolicLink != true else {
        throw LibraryError.invalid(L10n.text("套件不可包含符號連結。"))
      }
      if attributes.isRegularFile == true {
        total += attributes.fileSize ?? 0
        guard total <= 100 * 1024 * 1024 else {
          throw LibraryError.invalid(L10n.text("套件大於 100 MB。"))
        }
        let data = try Data(contentsOf: file)
        hash.update(data: Data(file.path.dropFirst(root.path.count).utf8))
        hash.update(data: data)
      }
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

public enum ExtensionInstaller {
  public static func install(_ source: URL, root: URL = PrivateStore.root) throws -> ExtensionRecord
  {
    try PrivateStore.prepare(root)
    let staging = root.appendingPathComponent("Staging-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: staging) }
    var package = source
    if source.pathExtension.lowercased() == "popclipextz" {
      let listing = try ProcessRunner.run("/usr/bin/zipinfo", ["-l", source.path], timeout: 10)
      guard listing.status == 0 else { throw LibraryError.invalid(L10n.text("無法讀取壓縮套件。")) }
      var total = 0
      var count = 0
      for line in listing.stdout.components(separatedBy: .newlines) {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard let first = fields.first, first.count == 10,
          first.first == "-" || first.first == "d" || first.first == "l"
        else { continue }
        guard first.first != "l", fields.count >= 9 else {
          throw LibraryError.invalid(L10n.text("壓縮套件不可包含符號連結。"))
        }
        total += Int(fields[3]) ?? 0
        count += 1
      }
      guard total <= 100 * 1024 * 1024, count <= 10000 else {
        throw LibraryError.invalid(L10n.text("壓縮套件超出容量上限。"))
      }
      let paths = try ProcessRunner.run("/usr/bin/zipinfo", ["-1", source.path], timeout: 10).stdout
        .components(separatedBy: .newlines).filter { !$0.isEmpty }
      for path in paths { _ = try Manifest.confinedFile(path, root: staging) }
      let extraction = try ProcessRunner.run(
        "/usr/bin/ditto", ["-xk", source.path, staging.path], timeout: 15)
      guard extraction.status == 0 else { throw LibraryError.invalid(L10n.text("無法解壓套件。")) }
      let entries = try FileManager.default.contentsOfDirectory(
        at: staging, includingPropertiesForKeys: nil
      ).filter { $0.pathExtension.lowercased() == "popclipext" }
      guard entries.count == 1 else {
        throw LibraryError.invalid(L10n.text("壓縮檔需要包含一個 .popclipext 資料夾。"))
      }
      package = entries[0]
    } else if source.pathExtension.lowercased() != "popclipext" {
      let text = try String(contentsOf: source, encoding: .utf8)
      _ = try Manifest.parseSnippet(text, filename: source.lastPathComponent)
      package = staging.appendingPathComponent("Snippet.popclipext", isDirectory: true)
      try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
      let ext = source.pathExtension.isEmpty ? "yaml" : source.pathExtension
      try Data(text.utf8).write(to: package.appendingPathComponent("Config." + ext))
    }
    var record = try Manifest.parsePackage(package)
    let destinationParent = root.appendingPathComponent("Extensions", isDirectory: true)
    try FileManager.default.createDirectory(
      at: destinationParent, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let destination = destinationParent.appendingPathComponent(
      String(Manifest.digest(Data(record.id.utf8)).prefix(16)) + "-"
        + String(record.digest.prefix(12)) + ".popclipext")
    if !FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.copyItem(at: package, to: destination)
    }
    if let enumerator = FileManager.default.enumerator(
      at: destination, includingPropertiesForKeys: [.isDirectoryKey])
    {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: destination.path)
      for case let file as URL in enumerator {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let directory = (attributes[.type] as? FileAttributeType) == .typeDirectory
        let executable = ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111 != 0
        try FileManager.default.setAttributes(
          [.posixPermissions: directory || executable ? 0o700 : 0o600], ofItemAtPath: file.path)
      }
    }
    record.packagePath = destination.path
    return record
  }
}
