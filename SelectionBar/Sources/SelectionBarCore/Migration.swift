import Foundation
import SQLite3

public struct MigrationSummary: Codable, Equatable, Sendable {
  public var layoutItems: Int
  public var extensionPackages: Int
  public var optionValues: Int
  public var disabledItems: Int
  public var groups: Int
  public var unmappedPreferenceKeys: [String]
  public var notes: [String]
  public var changed: Bool
}

public enum PopClipMigration {
  public static func migrate(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    destination: URL = PrivateStore.root, existing: Library? = nil,
    overwriteCustomization: Bool = false
  ) throws -> (Library, MigrationSummary) {
    let source = home.appendingPathComponent(
      "Library/Application Support/PopClip", isDirectory: true)
    var prefs: [String: Any] = [:]
    for name in ["com.pilotmoon.popclip-setapp", "com.pilotmoon.popclip"] {
      let p = home.appendingPathComponent("Library/Preferences/\(name).plist")
      if let data = try? Data(contentsOf: p),
        let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil)
          as? [String: Any]
      {
        prefs.merge(dictionary) { _, new in new }
      }
    }
    let sourceExtensions = source.appendingPathComponent("Extensions", isDirectory: true)
    guard FileManager.default.fileExists(atPath: source.path) || !prefs.isEmpty else {
      throw LibraryError.invalid(L10n.text("未找到 PopClip 設定或擴充。"))
    }
    let db = source.appendingPathComponent("Data/PopClip.sqlite")
    var imported = Library()
    var notes: [String] = []
    var optionCount = 0
    let packages =
      ((try? FileManager.default.contentsOfDirectory(
        at: sourceExtensions, includingPropertiesForKeys: nil)) ?? []).filter {
        $0.pathExtension == "popclipext"
      }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    var records: [ExtensionRecord] = []
    for package in packages {
      do { records.append(try Manifest.parsePackage(package)) } catch {
        notes.append(
          L10n.text(
            "未能匯入套件 %1$@：%2$@", String(describing: package.lastPathComponent),
            String(describing: error.localizedDescription)))
      }
    }
    if FileManager.default.fileExists(atPath: db.path) {
      let reader = try ReadOnlyDatabase(db)
      let layoutColumns = Set(
        try reader.query("PRAGMA table_info(ZLAYOUTITEM)").compactMap { $0["name"]?.string })
      let optionalColumns = ["ZICON", "ZCOLOR"].filter { layoutColumns.contains($0) }.map {
        "," + $0
      }.joined()
      let rows = try reader.query(
        "SELECT Z_PK,ZIDENTIFIER,ZPROVIDERIDENTIFIER,ZNAME,ZKIND,ZPARENT,ZENABLED,ZSORTKEY,ZPRESENTATIONMODE"
          + optionalColumns + " FROM ZLAYOUTITEM WHERE ZTRASHEDAT IS NULL ORDER BY ZSORTKEY,Z_PK"
      )
      let parents = Dictionary(
        rows.compactMap { row -> (String, String)? in
          guard let pk = row["Z_PK"], let id = row["ZIDENTIFIER"] else { return nil }
          return (pk.string, id.string)
        }, uniquingKeysWith: { a, _ in a })
      imported.layout = rows.compactMap { row in
        guard let id = row["ZIDENTIFIER"]?.string, !id.isEmpty else { return nil }
        let kind = Int(row["ZKIND"]?.string ?? "1") ?? 1
        var entry = LayoutEntry(
          id: id, provider: row["ZPROVIDERIDENTIFIER"]?.string ?? "", name: row["ZNAME"]?.string,
          enabled: kind == 1 ? row["ZENABLED"]?.string == "1" : true,
          order: Double(row["ZSORTKEY"]?.string ?? "0") ?? 0,
          parent: row["ZPARENT"].flatMap { parents[$0.string] },
          presentation: Int(row["ZPRESENTATIONMODE"]?.string ?? "0") ?? 0,
          kind: kind,
          icon: row["ZICON"], color: row["ZCOLOR"]?.string)
        entry.sourceEnabled = row["ZENABLED"]?.string == "1"
        return entry
      }
      // A modern layout owns its option namespace even when no row exists for
      // a particular option. That means the option's current default, not an
      // obsolete package-wide preference left over from the legacy app.
      for index in imported.layout.indices
      where records.contains(where: { $0.id == imported.layout[index].provider }) {
        imported.layout[index].options = [:]
      }
      let optionColumns = Set(
        try reader.query("PRAGMA table_info(ZOPTIONVALUE)").compactMap { $0["name"]?.string })
      let optionOrder =
        (optionColumns.contains("ZRECORDIDENTIFIER") ? "ZRECORDIDENTIFIER DESC," : "")
        + (optionColumns.contains("Z_PK") ? "Z_PK" : "rowid") + " DESC"
      let options = try reader.query(
        "SELECT ZIDENTIFIER,ZLAYOUTITEMIDENTIFIER,ZSTRINGVALUE,ZBOOLVALUE,ZKIND FROM ZOPTIONVALUE ORDER BY "
          + optionOrder)
      var seenOptions: Set<SourceOptionKey> = []
      for row in options {
        guard let id = row["ZIDENTIFIER"]?.string,
          let layoutID = row["ZLAYOUTITEMIDENTIFIER"]?.string,
          seenOptions.insert(SourceOptionKey(layout: layoutID, option: id)).inserted,
          let layoutIndex = imported.layout.firstIndex(where: {
            $0.id == row["ZLAYOUTITEMIDENTIFIER"]?.string
          }),
          let recordIndex = records.firstIndex(where: {
            $0.id == imported.layout[layoutIndex].provider
          })
        else { continue }
        let isSecret =
          records[recordIndex].config["options"]?.array.contains { option in
            let d = option.object
            return d["identifier"]?.string == id
              && ["secret", "password"].contains(d["type"]?.string ?? "")
          } == true
          || ["authsecret", "password", "token", "apikey"].contains(where: id.lowercased().contains)
        if isSecret {
          notes.append(
            L10n.text("%1$@ 的秘密選項需要重新輸入。", String(describing: records[recordIndex].name)))
          continue
        }
        // A non-value latest row retires older values. Do not resurrect an old
        // string, coerce a stale string column over a boolean, or import null as
        // an explicit empty value that would suppress the current default.
        switch row["ZKIND"]?.string {
        case "1":
          imported.layout[layoutIndex].options?[id] = row["ZSTRINGVALUE"] ?? .string("")
        case "2":
          imported.layout[layoutIndex].options?[id] = .bool(row["ZBOOLVALUE"]?.string == "1")
        default: continue
        }
        optionCount += 1
      }
    }
    if imported.layout.isEmpty {
      let order =
        prefs["CombinedItemOrder"] as? [String] ?? [
          "search", "openlink", "cut", "copy", "paste", "lookup",
        ] + records.map { "ext-" + $0.id }
      imported.layout = order.enumerated().map { index, token in
        let provider =
          token.hasPrefix("ext-") ? String(token.dropFirst(4)) : "app.popclip.builtin." + token
        return LayoutEntry(
          id: "import-" + token, provider: provider,
          enabled: prefs["enable-action-" + token] as? Bool ?? true, order: Double(index) * 1000)
      }
    }
    for index in records.indices {
      for (key, value) in prefs where key.hasPrefix("extension#" + records[index].id + "#") {
        let option = String(key.dropFirst(("extension#" + records[index].id + "#").count))
        guard records[index].options[option] == nil, !option.lowercased().contains("secret"),
          !option.lowercased().contains("token")
        else { continue }
        if records[index].config["options"]?.array.contains(where: {
          $0.object["identifier"]?.string == option
            && ["secret", "password"].contains($0.object["type"]?.string ?? "")
        }) == true {
          continue
        }
        records[index].options[option] = Value(any: value)
        optionCount += 1
      }
    }
    imported.settings.enabled = prefs["PopEnabled"] as? Bool ?? true
    imported.extensions = records
    imported.materializeInstanceOptions()
    imported.settings.websiteRules = WebsiteRules.imported(
      prefs["Rules_WebsitesList"] ?? prefs["user-websites-list"])
    imported.settings.excludedApps += prefs["Rules_AppsList"] as? [String] ?? []
    imported.settings.includedAppsOnly = (prefs["Rules_AppsList_Mode"] as? String) == "include"
    imported.settings.appearance = prefs["PopupColor"] as? String ?? "auto"
    if let size = prefs["PopupSize"] as? Double { imported.settings.size = min(52, max(26, size)) }
    if let position = prefs["PopupPosition"] as? String {
      imported.settings.placement = position.lowercased().contains("below") ? "below" : "above"
    }
    for key in ["ExcludedApps", "BlockedApps", "DisabledApps"] {
      imported.settings.excludedApps += prefs[key] as? [String] ?? []
    }
    if let hotkey = prefs["HotKey"] as? String { imported.settings.hotkey = hotkey }
    let mapped: Set<String> = [
      "PopEnabled", "PopupColor", "PopupSize", "PopupPosition", "ExcludedApps", "BlockedApps",
      "DisabledApps", "HotKey", "CombinedItemOrder", "Rules_WebsitesList", "user-websites-list",
      "Rules_AppsList", "Rules_AppsList_Mode",
    ]
    let migrationKeys = prefs.keys.filter {
      let key = $0.lowercased()
      return !["secret", "token", "password"].contains(where: key.contains)
        && (mapped.contains($0) || $0.hasPrefix("enable-action-"))
    }
    imported.settings.importedRawPreferences = Dictionary(
      uniqueKeysWithValues: migrationKeys.map { ($0, Value(any: prefs[$0]!)) })
    let preserved = retainedPreferences(prefs)
    let unmapped = preserved.keys.filter {
      !mapped.contains($0) && !$0.hasPrefix("extension#") && !$0.hasPrefix("enable-action-")
    }.sorted()
    // Keep genuinely untranslated preferences in a private typed sidecar. The
    // report must not call a discarded key "preserved".
    try PrivateStore.prepare(destination)
    let preservedData = try PropertyListSerialization.data(
      fromPropertyList: preserved, format: .binary, options: 0)
    let preservedURL = destination.appendingPathComponent("original-settings.plist")
    if (try? Data(contentsOf: preservedURL)) != preservedData {
      try preservedData.write(to: preservedURL, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: preservedURL.path)
    }
    let fingerprintEncoder = JSONEncoder()
    fingerprintEncoder.outputFormatting = [.sortedKeys]
    let fingerprintData = try fingerprintEncoder.encode(
      MigrationFingerprint(
        layout: imported.layout, extensions: records.map { [$0.id, $0.digest] },
        options: records.map(\.options), settings: imported.settings))
    let fingerprint = Manifest.digest(fingerprintData)
    var summary = MigrationSummary(
      layoutItems: imported.layout.count, extensionPackages: records.count,
      optionValues: optionCount,
      disabledItems: imported.layout.filter { $0.kind == 1 && !$0.enabled }.count,
      groups: imported.layout.filter(\.isGroup).count, unmappedPreferenceKeys: unmapped,
      notes: notes, changed: true)
    if let existing, existing.migrationFingerprint == fingerprint {
      summary.changed = false
      return (existing, summary)
    }
    if let existing, existing.migrationFingerprint != nil, !overwriteCustomization {
      summary.changed = false
      summary.notes.append(L10n.text("保留 SelectionBar 修改。再次匯入會更新來源副本；按「重設為 PopClip 設定」才覆寫排列。"))
      return (existing, summary)
    }
    for index in records.indices {
      let options = records[index].options
      records[index] = try ExtensionInstaller.install(
        URL(fileURLWithPath: records[index].packagePath), root: destination)
      records[index].options = options
    }
    imported.extensions = records
    imported.migrationFingerprint = fingerprint
    imported.migratedAt = Date()
    notes.append(L10n.text("未讀取 PopClip 鑰匙圈、活動紀錄或選取文字。網路／腳本只會在你點擊動作後執行。"))
    imported.notes = notes
    try PrivateStore.save(imported, at: destination)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let report = destination.appendingPathComponent("migration-summary.json")
    try encoder.encode(summary).write(to: report, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: report.path)
    return (imported, summary)
  }
  private struct SourceOptionKey: Hashable {
    var layout: String
    var option: String
  }
  private struct MigrationFingerprint: Codable {
    var layout: [LayoutEntry]
    var extensions: [[String]]
    var options: [[String: Value]]
    var settings: Settings
  }
  private static func retainedPreferences(_ object: [String: Any]) -> [String: Any] {
    let excluded = [
      "secret", "token", "password", "credential", "apikey", "privatekey", "license", "licence",
      "activation", "trial", "receipt", "usage", "activity", "launchcount",
    ]
    return object.reduce(into: [:]) { result, entry in
      guard !entry.key.hasPrefix("extension#") else { return }
      let key = entry.key.lowercased().filter { $0.isLetter || $0.isNumber }
      guard !excluded.contains(where: key.contains) else { return }
      result[entry.key] = retainedValue(entry.value)
    }
  }
  private static func retainedValue(_ value: Any) -> Any {
    if let object = value as? [String: Any] { return retainedPreferences(object) }
    if let array = value as? [Any] { return array.map(retainedValue) }
    return value
  }
}

struct SQLiteReadFailure: LocalizedError {
  let phase: String
  let primaryCode: Int32
  let extendedCode: Int32
  var errorDescription: String? {
    L10n.text(
      "PopClip 唯讀設定資料庫未能完成 %1$@（SQLite %2$@／%3$@）；原設定未變更。", String(describing: phase),
      String(describing: primaryCode), String(describing: extendedCode))
  }
}

final class ReadOnlyDatabase {
  private var db: OpaquePointer?
  init(_ url: URL) throws {
    let status = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
    guard status == SQLITE_OK else {
      let error = failure("open", status: status)
      sqlite3_close(db)
      db = nil
      throw error
    }
    sqlite3_busy_timeout(db, 1000)
    // Keep layout, per-instance options and schema under one read snapshot.
    let transaction = sqlite3_exec(db, "BEGIN DEFERRED TRANSACTION", nil, nil, nil)
    guard transaction == SQLITE_OK else {
      let error = failure("begin", status: transaction)
      sqlite3_close(db)
      db = nil
      throw error
    }
  }
  deinit { sqlite3_close(db) }
  func query(_ sql: String) throws -> [[String: Value]] {
    var statement: OpaquePointer?
    let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    guard prepared == SQLITE_OK else {
      let error = failure("prepare", status: prepared)
      sqlite3_finalize(statement)
      throw error
    }
    defer { sqlite3_finalize(statement) }
    var result: [[String: Value]] = []
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { break }
      guard status == SQLITE_ROW else { throw failure("step", status: status) }
      var row: [String: Value] = [:]
      for column in 0..<sqlite3_column_count(statement) {
        let name = String(cString: sqlite3_column_name(statement, column))
        if sqlite3_column_type(statement, column) != SQLITE_NULL,
          let text = sqlite3_column_text(statement, column)
        {
          row[name] = .string(String(cString: text))
        }
      }
      result.append(row)
    }
    return result
  }
  private func failure(_ phase: String, status: Int32) -> SQLiteReadFailure {
    SQLiteReadFailure(
      phase: phase, primaryCode: status & 0xff, extendedCode: sqlite3_extended_errcode(db))
  }
}
