import Foundation
import SQLite3
import XCTest

@testable import SelectionBarCore

final class MigrationTests: XCTestCase {
  var root: URL!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SelectionBarMigration-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
  func fixture() throws -> (URL, URL) {
    let home = root.appendingPathComponent("home")
    let support = home.appendingPathComponent("Library/Application Support/PopClip")
    let extensions = support.appendingPathComponent("Extensions")
    let prefs = home.appendingPathComponent("Library/Preferences")
    try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
    let package = extensions.appendingPathComponent("Synthetic.popclipext")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try Data(
      "name: Synthetic\nidentifier: dev.test.synthetic\nurl: https://example.invalid?q=***\noptions:\n  - identifier: lang\n    type: string\n    defaultValue: en"
        .utf8
    ).write(to: package.appendingPathComponent("Config.yaml"))
    let preferences: [String: Any] = [
      "PopEnabled": true, "PopupColor": "dark",
      "CombinedItemOrder": ["copy", "ext-dev.test.synthetic"],
      "extension#dev.test.synthetic#lang": "ja", "UsageCount": 12,
      "FutureUISetting": ["level": 3, "api_key": "synthetic-not-a-secret"],
    ]
    try PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0)
      .write(to: prefs.appendingPathComponent("com.pilotmoon.popclip.plist"))
    return (home, root.appendingPathComponent("store"))
  }
  func testImportCopiesNoScriptsAndIsIdempotent() throws {
    let (home, store) = try fixture()
    let first = try PopClipMigration.migrate(home: home, destination: store)
    XCTAssertEqual(first.1.extensionPackages, 1)
    XCTAssertEqual(first.0.extensions[0].options["lang"], .string("ja"))
    XCTAssertFalse(first.1.unmappedPreferenceKeys.contains("UsageCount"))
    XCTAssertTrue(first.1.unmappedPreferenceKeys.contains("FutureUISetting"))
    let backup = try XCTUnwrap(
      try PropertyListSerialization.propertyList(
        from: Data(contentsOf: store.appendingPathComponent("original-settings.plist")), format: nil
      ) as? [String: Any])
    XCTAssertEqual((backup["FutureUISetting"] as? [String: Any])?["level"] as? Int, 3)
    XCTAssertNil((backup["FutureUISetting"] as? [String: Any])?["api_key"])
    XCTAssertNil(backup["UsageCount"])
    XCTAssertEqual(first.0.settings.appearance, "dark")
    let second = try PopClipMigration.migrate(home: home, destination: store, existing: first.0)
    XCTAssertFalse(second.1.changed)
    XCTAssertEqual(second.0, first.0)
    let attributes = try FileManager.default.attributesOfItem(
      atPath: store.appendingPathComponent("library.json").path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }
  func testModernDatabaseOverridesStaleLegacyOrderAndFlags() throws {
    let (home, store) = try fixture()
    let dbURL = home.appendingPathComponent(
      "Library/Application Support/PopClip/Data/PopClip.sqlite")
    try FileManager.default.createDirectory(
      at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    let sql = """
      CREATE TABLE ZLAYOUTITEM(Z_PK INTEGER,ZIDENTIFIER TEXT,ZPROVIDERIDENTIFIER TEXT,ZNAME TEXT,ZKIND INTEGER,ZPARENT INTEGER,ZENABLED INTEGER,ZSORTKEY REAL,ZPRESENTATIONMODE INTEGER,ZTRASHEDAT REAL);
      CREATE TABLE ZOPTIONVALUE(ZIDENTIFIER TEXT,ZLAYOUTITEMIDENTIFIER TEXT,ZSTRINGVALUE TEXT,ZBOOLVALUE INTEGER,ZKIND INTEGER);
      INSERT INTO ZLAYOUTITEM VALUES(1,'group','','My Group',2,NULL,1,1000,0,NULL);
      INSERT INTO ZLAYOUTITEM VALUES(2,'ext','dev.test.synthetic',NULL,1,1,0,2000,2,NULL);
      INSERT INTO ZOPTIONVALUE VALUES('lang','ext','ko',NULL,1);
      """
    XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    let result = try PopClipMigration.migrate(home: home, destination: store)
    XCTAssertEqual(result.0.layout.count, 2)
    XCTAssertEqual(result.0.layout[1].parent, "group")
    XCTAssertFalse(result.0.layout[1].enabled)
    XCTAssertEqual(result.0.layout[1].presentation, 2)
    XCTAssertEqual(result.0.record(forSelection: "ext")?.options["lang"], .string("ko"))
    XCTAssertEqual(result.1.groups, 1)
  }
  func testModernDuplicateOptionsFoldersStylesAndWebsiteRulesRemainIndependent() throws {
    let (home, store) = try fixture()
    let preferencesURL = home.appendingPathComponent(
      "Library/Preferences/com.pilotmoon.popclip.plist")
    var preferences = try XCTUnwrap(
      PropertyListSerialization.propertyList(
        from: Data(contentsOf: preferencesURL), format: nil) as? [String: Any])
    preferences["Rules_WebsitesList"] = ["example.com", "example.org/private"]
    preferences["Rules_AppsList"] = ["dev.test.editor"]
    preferences["Rules_AppsList_Mode"] = "include"
    try PropertyListSerialization.data(fromPropertyList: preferences, format: .binary, options: 0)
      .write(to: preferencesURL)
    let dbURL = home.appendingPathComponent(
      "Library/Application Support/PopClip/Data/PopClip.sqlite")
    try FileManager.default.createDirectory(
      at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    let sql = """
      CREATE TABLE ZLAYOUTITEM(Z_PK INTEGER,ZIDENTIFIER TEXT,ZPROVIDERIDENTIFIER TEXT,ZNAME TEXT,ZKIND INTEGER,ZPARENT INTEGER,ZENABLED INTEGER,ZSORTKEY REAL,ZPRESENTATIONMODE INTEGER,ZTRASHEDAT REAL,ZICON TEXT,ZCOLOR TEXT);
      CREATE TABLE ZOPTIONVALUE(ZIDENTIFIER TEXT,ZLAYOUTITEMIDENTIFIER TEXT,ZSTRINGVALUE TEXT,ZBOOLVALUE INTEGER,ZKIND INTEGER);
      INSERT INTO ZLAYOUTITEM VALUES(1,'folder','','Work',2,NULL,0,1000,0,NULL,'symbol:tray','purple');
      INSERT INTO ZLAYOUTITEM VALUES(2,'a','dev.test.synthetic',NULL,1,1,1,2000,0,NULL,NULL,NULL);
      INSERT INTO ZLAYOUTITEM VALUES(3,'b','dev.test.synthetic',NULL,1,1,1,3000,0,NULL,NULL,NULL);
      INSERT INTO ZLAYOUTITEM VALUES(4,'divider','',NULL,3,1,0,4000,0,NULL,NULL,NULL);
      INSERT INTO ZOPTIONVALUE VALUES('lang','a','ko',NULL,1);
      INSERT INTO ZOPTIONVALUE VALUES('lang','b','en',NULL,1);
      INSERT INTO ZOPTIONVALUE VALUES('authsecret','b','synthetic-secret-must-not-import',NULL,1);
      """
    XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    let first = try PopClipMigration.migrate(home: home, destination: store)
    XCTAssertEqual(first.0.record(forSelection: "a")?.options["lang"], .string("ko"))
    XCTAssertEqual(first.0.record(forSelection: "b")?.options["lang"], .string("en"))
    XCTAssertNil(first.0.record(forSelection: "b")?.options["authsecret"])
    XCTAssertEqual(first.0.layout.first?.sourceEnabled, false)
    XCTAssertEqual(first.0.layout.first?.icon, .string("symbol:tray"))
    XCTAssertEqual(LayoutTree.enabledEntries(first.0.layout).count, 4)
    XCTAssertEqual(first.1.disabledItems, 0)
    XCTAssertEqual(first.0.settings.websiteRules.count, 2)
    XCTAssertTrue(first.0.settings.includedAppsOnly)
    XCTAssertEqual(first.0.settings.excludedApps, ["dev.test.editor"])
    var customized = first.0
    customized.layout[1].options?["lang"] = .string("fr")
    let second = try PopClipMigration.migrate(home: home, destination: store, existing: customized)
    XCTAssertFalse(second.1.changed)
    XCTAssertEqual(second.0.record(forSelection: "a")?.options["lang"], .string("fr"))
    XCTAssertEqual(second.0.record(forSelection: "b")?.options["lang"], .string("en"))
  }
  func testNewestRecordIdentifierAndValueKindOverrideInsertionOrderAndLegacyValues() throws {
    let (home, store) = try fixture()
    let package = home.appendingPathComponent(
      "Library/Application Support/PopClip/Extensions/Synthetic.popclipext/Config.yaml")
    try Data(
      """
      name: Synthetic
      identifier: dev.test.synthetic
      url: https://example.invalid?q=***
      options:
        - {identifier: lang, type: string, defaultValue: en}
        - {identifier: enabled, type: boolean}
        - {identifier: retired, type: string, defaultValue: default}
      """.utf8
    ).write(to: package)
    let dbURL = home.appendingPathComponent(
      "Library/Application Support/PopClip/Data/PopClip.sqlite")
    try FileManager.default.createDirectory(
      at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    let sql = """
      CREATE TABLE ZLAYOUTITEM(Z_PK INTEGER,ZIDENTIFIER TEXT,ZPROVIDERIDENTIFIER TEXT,ZNAME TEXT,ZKIND INTEGER,ZPARENT INTEGER,ZENABLED INTEGER,ZSORTKEY REAL,ZPRESENTATIONMODE INTEGER,ZTRASHEDAT REAL);
      CREATE TABLE ZOPTIONVALUE(Z_PK INTEGER,ZRECORDIDENTIFIER TEXT,ZIDENTIFIER TEXT,ZLAYOUTITEMIDENTIFIER TEXT,ZSTRINGVALUE TEXT,ZBOOLVALUE INTEGER,ZKIND INTEGER);
      INSERT INTO ZLAYOUTITEM VALUES(1,'a','dev.test.synthetic',NULL,1,NULL,1,1000,0,NULL);
      INSERT INTO ZLAYOUTITEM VALUES(2,'b','dev.test.synthetic',NULL,1,NULL,1,2000,0,NULL);
      INSERT INTO ZOPTIONVALUE VALUES(1,'z-newest','lang','a','ko',NULL,1);
      INSERT INTO ZOPTIONVALUE VALUES(2,'a-old','lang','a','fr',NULL,1);
      INSERT INTO ZOPTIONVALUE VALUES(3,'z-newest','enabled','a','stale-string',0,2);
      INSERT INTO ZOPTIONVALUE VALUES(4,'a-old','enabled','a','1',1,2);
      INSERT INTO ZOPTIONVALUE VALUES(5,'z-newest','retired','a',NULL,NULL,3);
      INSERT INTO ZOPTIONVALUE VALUES(6,'a-old','retired','a','must-not-return',NULL,1);
      """
    XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    let imported = try PopClipMigration.migrate(home: home, destination: store).0
    let a = try XCTUnwrap(imported.record(forSelection: "a"))
    XCTAssertEqual(a.options["lang"], .string("ko"))
    XCTAssertEqual(a.options["enabled"], .bool(false))
    XCTAssertNil(a.options["retired"])
    XCTAssertEqual(
      ExtensionOptions.effective(a.config["options"]?.array ?? [], stored: a.options)["retired"],
      .string("default"))
    let b = try XCTUnwrap(imported.record(forSelection: "b"))
    XCTAssertNil(
      b.options["lang"],
      "An authoritative modern namespace must not resurrect obsolete package-wide preferences")
    XCTAssertEqual(
      ExtensionOptions.effective(b.config["options"]?.array ?? [], stored: b.options)["lang"],
      .string("en"))
    XCTAssertEqual(
      imported.extensions.first?.options["lang"], .string("ja"),
      "Legacy metadata remains preserved without changing modern behavior")
    let bytes = try Data(contentsOf: dbURL)
    let second = try PopClipMigration.migrate(home: home, destination: store, existing: imported)
    XCTAssertFalse(second.1.changed)
    XCTAssertEqual(try Data(contentsOf: dbURL), bytes)
  }
}
