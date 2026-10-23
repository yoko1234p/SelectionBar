import XCTest

@testable import SelectionBarCore

final class ExtensionOptionsTests: XCTestCase {
  func testDocumentedBooleanMultipleAndNoneDefaults() {
    let definitions: [Value] = [
      .object(["identifier": .string("flag"), "type": .string("boolean")]),
      .object([
        "identifier": .string("choice"), "type": .string("multiple"),
        "values": .array([.string("first"), .string("second")]),
      ]),
      .object([
        "identifier": .string("optional"), "type": .string("multiple"), "allowNone": .bool(true),
        "values": .array([.string("first")]),
      ]),
    ]
    let values = ExtensionOptions.effective(definitions, stored: [:])
    XCTAssertEqual(values["flag"], .bool(true))
    XCTAssertEqual(values["choice"], .string("first"))
    XCTAssertEqual(values["optional"], .string(""))
  }
  func testMigrationAliasAndEphemeralPasswordAreHandledByType() {
    let definitions: [Value] = [
      .object([
        "identifier": .string("replacement"), "type": .string("string"),
        "migrateFrom": .string("old"),
      ]),
      .object(["identifier": .string("concealed"), "type": .string("password")]),
      .object(["identifier": .string("section"), "type": .string("heading")]),
    ]
    let values = ExtensionOptions.effective(
      definitions,
      stored: [
        "old": .string("configured"), "replacement": .string("default"),
        "concealed": .string("synthetic"), "section": .string("not an option"),
      ])
    XCTAssertEqual(values["replacement"], .string("configured"))
    XCTAssertNil(values["concealed"])
    XCTAssertNil(values["section"])
  }
  func testOnlyNonemptyStringMigrationShadowsAndSecretsHaveNoDefault() {
    let definitions: [Value] = [
      .object([
        "identifier": .string("new"), "type": .string("string"), "migrateFrom": .string("old"),
        "defaultValue": .string("default"),
      ]),
      .object([
        "identifier": .string("credential"), "type": .string("secret"),
        "defaultValue": .string("must-not-be-used"),
      ]),
    ]
    for old in [Value.bool(true), .bool(false), .number(42), .string("")] {
      XCTAssertEqual(
        ExtensionOptions.effective(definitions, stored: ["old": old])["new"], .string("default"))
    }
    XCTAssertEqual(ExtensionOptions.effective(definitions, stored: [:])["credential"], .string(""))
    XCTAssertEqual(
      ExtensionOptions.effective(
        definitions, stored: ["credential": .string("owned-explicit-fixture")])["credential"],
      .string("owned-explicit-fixture"))
  }
}
