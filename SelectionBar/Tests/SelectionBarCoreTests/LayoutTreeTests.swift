import XCTest

@testable import SelectionBarCore

final class LayoutTreeTests: XCTestCase {
  func testDisabledGroupsSuppressChildrenAndDoNotReorderVisibleEntries() {
    let entries = [
      LayoutEntry(id: "root", provider: "copy", order: 2),
      LayoutEntry(id: "hidden", provider: "", enabled: false, order: 0, kind: 0),
      LayoutEntry(id: "hidden-child", provider: "module", order: 1, parent: "hidden"),
      LayoutEntry(id: "group", provider: "", order: 3, kind: 0),
      LayoutEntry(id: "nested", provider: "", order: 4, parent: "group", kind: 0),
      LayoutEntry(id: "child", provider: "module", order: 5, parent: "nested"),
    ]
    XCTAssertEqual(
      LayoutTree.enabledEntries(entries).map(\.id), ["root", "group", "nested", "child"])
  }
  func testMalformedCyclesAndMissingParentsCannotPopulate() {
    let entries = [
      LayoutEntry(id: "a", provider: "", order: 0, parent: "b", kind: 0),
      LayoutEntry(id: "b", provider: "", order: 1, parent: "a", kind: 0),
      LayoutEntry(id: "child", provider: "module", order: 2, parent: "a"),
      LayoutEntry(id: "orphan", provider: "module", order: 3, parent: "missing"),
      LayoutEntry(id: "action", provider: "module", order: 4),
      LayoutEntry(id: "wrong-parent", provider: "module", order: 5, parent: "action"),
    ]
    XCTAssertEqual(LayoutTree.enabledEntries(entries).map(\.id), ["action"])
  }
}
