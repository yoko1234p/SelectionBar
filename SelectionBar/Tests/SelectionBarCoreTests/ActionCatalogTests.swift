import XCTest

@testable import SelectionBarCore

final class ActionCatalogTests: XCTestCase {
  func testStaticSubmenuDoesNotInheritParentFiltersCommandsOrSteps() throws {
    let parent = ExtensionAction(
      id: "parent", title: "Parent",
      config: [
        "url": .string("https://parent.invalid/***"),
        "requirements": .array([.string("url")]), "after": .string("paste-result"),
        "before": .string("cut"), "capturehtml": .bool(true),
        "icon": .string("symbol:star"),
        "submenu": .array([
          .object(["title": .string("Child"), "javascript": .string("return 'child';")]),
          .object(["separator": .bool(true)]),
          .object([
            "title": .string("Nested"),
            "submenu": .array([
              .object([
                "title": .string("Leaf"), "requirements": .array([]),
                "url": .string("https://child.invalid"),
              ])
            ]),
          ]),
        ]),
      ])
    let children = ActionCatalog.children(
      of: parent, name: "Fixture", context: ActionContext(text: "plain text"), options: [:])
    XCTAssertEqual(children.map(\.kind), ["javascript", "separator", "submenu"])
    XCTAssertNil(children[0].config["url"])
    XCTAssertNil(children[0].config["requirements"])
    XCTAssertNil(children[0].config["after"])
    XCTAssertNil(children[0].config["before"])
    XCTAssertNil(children[0].config["capturehtml"])
    XCTAssertNil(children[0].config["icon"])
    XCTAssertEqual(
      ActionCatalog.children(
        of: children[2], name: "Fixture", context: ActionContext(text: ""), options: [:]
      ).first?.kind, "url")
  }
  func testDefaultOptionRequirementsAndExplicitFalseHaveConsistentNativeVisibility() {
    let options: [Value] = [
      .object(["identifier": .string("enabled"), "type": .string("boolean")]),
      .object([
        "identifier": .string("choice"), "type": .string("multiple"),
        "values": .array([.string("first"), .string("second")]),
      ]),
    ]
    let action = ExtensionAction(
      id: "x", title: "Default",
      config: [
        "options": .array(options),
        "requirements": .array([.string("option-enabled=1"), .string("option-choice=first")]),
      ])
    XCTAssertNotNil(
      ActionMatcher.match(action, context: ActionContext(text: "hello"), options: [:]))
    XCTAssertNil(
      ActionMatcher.match(
        action, context: ActionContext(text: "hello"), options: ["enabled": .bool(false)]))
    XCTAssertNil(
      ActionMatcher.match(
        action, context: ActionContext(text: "hello"), options: ["choice": .string("second")]))
  }
}
