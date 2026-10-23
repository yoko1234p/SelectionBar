import Foundation
import XCTest

@testable import SelectionBarCore

final class ManifestTests: XCTestCase {
  var temporary: URL!
  override func setUpWithError() throws {
    temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SelectionBarTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temporary) }
  func package(_ config: String, name: String = "Config.yaml") throws -> URL {
    let p = temporary.appendingPathComponent(UUID().uuidString + ".popclipext")
    try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
    try Data(config.utf8).write(to: p.appendingPathComponent(name))
    return p
  }
  func testYAMLRequirementsAndAliases() throws {
    let p = try package(
      """
      Extension Name: Search
      Extension Identifier: dev.test.search
      Regular Expression: '[a-z]+'
      URL: https://example.com/?q=***
      Requirements: [text, '!paste']
      """)
    let record = try Manifest.parsePackage(p)
    XCTAssertEqual(record.name, "Search")
    XCTAssertEqual(record.id, "dev.test.search")
    XCTAssertEqual(record.actions.first?.kind, "url")
    XCTAssertEqual(record.actions.first?.config["regex"]?.string, "[a-z]+")
  }
  func testGeneratedPlistDoesNotOverrideActualJSON() throws {
    let p = try package(
      "{\"name\":\"Actual\",\"identifier\":\"dev.test.actual\",\"serviceName\":\"Test Service\"}",
      name: "Config.json")
    let metadata: [String: Any] = [
      "Extension Name": "Metadata", "Extension Identifier": "dev.test.actual",
    ]
    try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0).write(
      to: p.appendingPathComponent("Config.plist"))
    let record = try Manifest.parsePackage(p)
    XCTAssertEqual(record.name, "Actual")
    XCTAssertEqual(record.actions.first?.kind, "servicename")
  }
  func testInheritedActionProperties() throws {
    let p = try package(
      """
      name: Variants
      captureHtml: true
      actions:
        - title: A
          url: https://a.example/?q=***
        - title: B
          keyCombo: command b
      """)
    let r = try Manifest.parsePackage(p)
    XCTAssertEqual(r.actions.count, 2)
    XCTAssertEqual(r.actions[1].config["capturehtml"], .bool(true))
    XCTAssertEqual(r.actions[1].kind, "keycombo")
  }
  func testSnippetParsingDoesNotExecuteJavaScript() throws {
    let snippet = "// #popclip\n// name: Sample\nthrow Error('must not run during import');"
    let config = try Manifest.parseSnippet(snippet)
    XCTAssertEqual(config["name"], .string("Sample"))
    XCTAssertTrue(config["javascript"]?.string.contains("throw Error") == true)
  }
  func testRejectsTraversalAndSymlinkPackage() throws {
    XCTAssertThrowsError(try Manifest.confinedFile("../secret", root: temporary))
    XCTAssertThrowsError(try Manifest.confinedFile("/tmp/secret", root: temporary))
    let p = try package("name: Sample\nurl: https://example.com")
    try FileManager.default.createSymbolicLink(
      at: p.appendingPathComponent("outside"), withDestinationURL: temporary)
    XCTAssertThrowsError(try Manifest.parsePackage(p))
  }
  func testInstallIsIdempotentAndPreservesOriginal() throws {
    let source = try package(
      "name: Sample\nidentifier: dev.test.sample\nurl: https://example.com?q=***")
    let before = try Manifest.packageDigest(source)
    let store = temporary.appendingPathComponent("private")
    let first = try ExtensionInstaller.install(source, root: store)
    let second = try ExtensionInstaller.install(source, root: store)
    XCTAssertEqual(first, second)
    XCTAssertEqual(try Manifest.packageDigest(source), before)
    XCTAssertNotEqual(first.packagePath, source.path)
  }
  func testURLTemplateEncodingAndVariableBoundaries() {
    XCTAssertEqual(
      ActionMatcher.templateURL(
        "https://e.test?q=***&lang={popclip option lang}", text: "  a+b & 日  ",
        options: ["lang": .string("zh-HK")]), "https://e.test?q=a%2Bb%20%26%20%E6%97%A5&lang=zh-HK")
  }
  func testRequirementsNarrowBeforeRegex() {
    let action = ExtensionAction(
      id: "x", title: "x",
      config: ["requirements": .array([.string("url")]), "regex": .string("(?<=://)[^/]+")])
    let context = ActionContext(text: "See https://example.org/path now")
    XCTAssertEqual(
      ActionMatcher.match(action, context: context, options: [:])?.matchedText, "example.org")
  }
  func testUnknownRequirementNeverExecutes() {
    let action = ExtensionAction(
      id: "x", title: "x", config: ["requirements": .array([.string("unsupported")])])
    XCTAssertNil(ActionMatcher.match(action, context: ActionContext(text: "hello"), options: [:]))
  }
  func testKeyboardValidationIsAtomic() {
    XCTAssertEqual(
      try KeyCombo.parse("command shift B"), KeyCombo(code: 11, flags: (1 << 20) | (1 << 17)))
    XCTAssertThrowsError(try KeyCombo.parse("fake b"))
  }
  func testPlacementOnNegativeOriginSmallDisplay() {
    let visible = CGRect(x: -1710, y: 0, width: 1710, height: 1060)
    let frame = Placement.frame(
      anchor: CGRect(x: -20, y: 1040, width: 10, height: 10), size: CGSize(width: 900, height: 48),
      visible: visible, below: false)
    XCTAssertTrue(visible.contains(frame))
    XCTAssertLessThan(frame.maxY, 1040)
  }
  func testAppleScriptSubstitutionEscapesUntrustedSelection() {
    let result = ActionMatcher.substituteAppleScript(
      "return \"{popclip text}\"", variables: ["TEXT": "\" & do shell script \"bad\" & \""])
    XCTAssertEqual(result, "return \"\\\" & do shell script \\\"bad\\\" & \\\"\"")
  }
  func testCodeHeaderPreservesNestedOptionsAndInfersTypeScript() throws {
    let config = try Manifest.parseSnippet(
      "// #popclip\n// name: Typed\n// options:\n//   - identifier: prefix\n//     type: string\nconst value: string = popclip.input.text;\npopclip.copyText(value);",
      filename: "Config.js")
    XCTAssertEqual(config["options"]?.array.first?.object["identifier"], .string("prefix"))
    XCTAssertEqual(config["__sourceextension"], .string("ts"))
  }
  func testShellAndAppleScriptSnippetInference() throws {
    let shell = try Manifest.parseSnippet(
      "#!/usr/bin/env python3\n# #popclip\n# name: Test\nimport os\nprint(os.environ['POPCLIP_TEXT'])",
      filename: "Config.py")
    XCTAssertEqual(shell["shellscriptfile"], .string("Config.py"))
    XCTAssertEqual(shell["interpreter"], .string("python3"))
    let apple = try Manifest.parseSnippet(
      "-- #popclip\n-- name: Apple\nreturn \"hello\"", filename: "Config.popcliptxt")
    XCTAssertEqual(apple["applescript"], .string("return \"hello\""))
  }
}
