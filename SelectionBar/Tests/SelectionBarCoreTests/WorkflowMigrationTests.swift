import Foundation
import SelectionBarCore
import XCTest

final class WorkflowMigrationTests: XCTestCase {
  func testAppendPreservesOriginalBytesSettingsAndDisabledActions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var library = Library.initial
    try library.addBuiltIn("favorites")
    if let index = library.layout.firstIndex(where: { $0.provider.hasSuffix(".favorites") }) { library.layout[index].enabled = false }
    try PrivateStore.save(library, at: root)
    let file = root.appendingPathComponent("library.json")
    var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    var settings = try XCTUnwrap(raw["settings"] as? [String: Any])
    settings.removeValue(forKey: "spellingLanguages")
    settings["futureSetting"] = ["opaque": "literal layout ] \\\" value"]
    raw["settings"] = settings; raw["futureField"] = "retain"
    let before = try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
    try before.write(to: file)
    try PrivateStore.appendBuiltIns(["favorites", "vocabulary", "recipes"], at: root)
    let after = try Data(contentsOf: file)
    // Removing only the inserted bytes must reproduce the original file exactly.
    let firstMismatch = zip(before, after).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset ?? before.count
    let inserted = after.count - before.count
    XCTAssertEqual(Data(after.prefix(firstMismatch)) + Data(after.dropFirst(firstMismatch + inserted)), before)
    let result = try PrivateStore.load(at: root)
    XCTAssertEqual(result.layout.filter { $0.provider.hasSuffix(".favorites") }.count, 1)
    XCTAssertFalse(try XCTUnwrap(result.layout.first { $0.provider.hasSuffix(".favorites") }).enabled)
    XCTAssertTrue(result.layout.contains { $0.provider.hasSuffix(".recipes") })
    try PrivateStore.appendBuiltIns(["favorites", "vocabulary", "recipes"], at: root)
    XCTAssertEqual(try Data(contentsOf: file), after)
  }
}
