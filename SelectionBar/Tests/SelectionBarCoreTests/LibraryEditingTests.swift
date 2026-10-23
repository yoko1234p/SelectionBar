import Foundation
import XCTest

@testable import SelectionBarCore

final class LibraryEditingTests: XCTestCase {
  private func fixture() -> Library {
    var library = Library.initial
    library.layout = [
      LayoutEntry(id: "a", provider: "fixture", order: 0),
      LayoutEntry(id: "b", provider: "fixture", order: 1000),
    ]
    library.extensions = [
      ExtensionRecord(
        id: "fixture", name: "Fixture", packagePath: "/tmp",
        digest: "synthetic", config: [:], actions: [], options: ["language": .string("en")])
    ]
    return library
  }
  func testNestedFoldersCanMoveAndRejectCyclesWithoutChangingOrder() throws {
    var library = fixture()
    let folder = try library.createGroup(name: " Work ", id: "folder")
    let child = try library.createGroup(name: "Nested", parent: folder, id: "child")
    try library.moveEntry("b", toParent: child)
    XCTAssertEqual(library.layoutRows.map(\.id), ["a", "folder", "child", "b"])
    XCTAssertEqual(library.layoutRows.map(\.depth), [0, 0, 1, 2])
    let unchanged = library
    XCTAssertThrowsError(try library.moveEntry(folder, toParent: child))
    XCTAssertEqual(library, unchanged)
    XCTAssertThrowsError(try library.moveEntry("a", toParent: "a"))
    XCTAssertThrowsError(try library.createGroup(name: "  "))
    try library.moveEntry(folder, toParent: nil, before: "a")
    XCTAssertEqual(library.layoutRows.map(\.id), ["folder", "child", "b", "a"])
  }
  func testDeleteFolderKeepsChildrenInPlaceOrDeletesWholeSubtree() throws {
    var library = fixture()
    _ = try library.createGroup(name: "Folder", id: "folder")
    _ = try library.createGroup(name: "Nested", parent: "folder", id: "nested")
    try library.moveEntry("a", toParent: "nested")
    try library.moveEntry("folder", toParent: nil, before: "b")
    try library.deleteEntry("folder", keepChildren: true)
    XCTAssertEqual(library.layoutRows.map(\.id), ["nested", "a", "b"])
    XCTAssertNil(library.layout.first { $0.id == "nested" }?.parent)
    try library.deleteEntry("nested", keepChildren: false)
    XCTAssertEqual(library.layout.map(\.id), ["b"])
    XCTAssertEqual(library.extensions.count, 1)
  }
  func testDuplicateInstancesKeepIndependentOptionsAndSecretNamespace() throws {
    var library = fixture()
    library.materializeInstanceOptions()
    library.layout[1].options?["language"] = .string("ko")
    let duplicate = try library.duplicateEntry("a")
    let index = try XCTUnwrap(library.layout.firstIndex { $0.id == duplicate })
    library.layout[index].options?["language"] = .string("ja")
    let a = try XCTUnwrap(library.record(forSelection: "a"))
    let b = try XCTUnwrap(library.record(forSelection: "b"))
    let copy = try XCTUnwrap(library.record(forSelection: duplicate))
    XCTAssertEqual(a.options["language"], .string("en"))
    XCTAssertEqual(b.options["language"], .string("ko"))
    XCTAssertEqual(copy.options["language"], .string("ja"))
    XCTAssertEqual(Set([a.secretIdentifier, b.secretIdentifier, copy.secretIdentifier]).count, 3)
    XCTAssertEqual(a.legacySecretFallback, true)
    XCTAssertEqual(b.legacySecretFallback, false)
    XCTAssertEqual(copy.legacySecretFallback, false)
    XCTAssertEqual(a.id, copy.id)
  }
  func testDuplicateFolderRemapsEveryDescendantAndRetainsStyles() throws {
    var library = fixture()
    _ = try library.createGroup(
      name: "Folder", icon: .string("symbol:tray"), color: "blue", id: "folder")
    _ = try library.createGroup(name: "Nested", parent: "folder", id: "nested")
    try library.moveEntry("a", toParent: "nested")
    let copy = try library.duplicateEntry("folder")
    let descendants = library.descendants(of: copy)
    XCTAssertEqual(descendants.count, 2)
    XCTAssertTrue(descendants.isDisjoint(with: ["a", "nested", "folder"]))
    let cloned = try XCTUnwrap(library.layout.first { $0.id == copy })
    XCTAssertEqual(cloned.color, "blue")
    XCTAssertEqual(cloned.icon, .string("symbol:tray"))
    XCTAssertEqual(library.layoutRows.filter { descendants.contains($0.id) }.map(\.depth), [1, 2])
  }
  func testOldStoreDecodesNewSettingsAndMaterializesInstancesIdempotently() throws {
    let data = try JSONEncoder().encode(fixture())
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["settings"] = ["enabled": false, "hotkey": "command 0x31"]
    var decoded = try JSONDecoder().decode(
      Library.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertFalse(decoded.settings.enabled)
    XCTAssertTrue(decoded.settings.browserIntegration)
    XCTAssertTrue(decoded.settings.websiteRules.isEmpty)
    decoded.materializeInstanceOptions()
    let once = decoded
    decoded.materializeInstanceOptions()
    XCTAssertEqual(decoded, once)
    XCTAssertEqual(decoded.record(forSelection: "b")?.options["language"], .string("en"))
  }
}
