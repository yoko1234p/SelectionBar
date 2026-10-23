import Foundation
import XCTest

@testable import SelectionBarCore

final class PrivateStoreTests: XCTestCase {
  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
  func testCorruptFileCannotBeReplacedByDefaults() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("library.json")
    let original = Data("{unfinished private configuration".utf8)
    try original.write(to: file)
    XCTAssertThrowsError(try PrivateStore.load(at: root))
    XCTAssertThrowsError(try PrivateStore.save(.initial, at: root))
    XCTAssertEqual(try Data(contentsOf: file), original)
    let archive = try PrivateStore.recover(at: root)
    XCTAssertEqual(try Data(contentsOf: archive), original)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    XCTAssertEqual(try PrivateStore.load(at: root), .initial)
    try PrivateStore.save(.initial, at: root)
    XCTAssertEqual(try Data(contentsOf: archive), original)
    XCTAssertEqual(
      (try FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions]
        as? NSNumber)?.intValue, 0o600)
  }
  func testSymlinkDoesNotExposeOrOverwriteTarget() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("unchanged.json")
    try Data("target must stay unchanged".utf8).write(to: target)
    let file = root.appendingPathComponent("library.json")
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    XCTAssertThrowsError(try PrivateStore.load(at: root))
    XCTAssertThrowsError(try PrivateStore.save(.initial, at: root))
    let archive = try PrivateStore.recover(at: root)
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: archive.path), target.path)
    try PrivateStore.save(.initial, at: root)
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "target must stay unchanged")
  }
  func testOversizedSparseFileIsRejectedAndRecoverableWithoutReading() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("library.json")
    try Data().write(to: file)
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: UInt64(PrivateStore.maximumFileBytes + 1))
    try handle.close()
    XCTAssertThrowsError(try PrivateStore.load(at: root))
    XCTAssertThrowsError(try PrivateStore.save(.initial, at: root))
    let archive = try PrivateStore.recover(at: root)
    XCTAssertEqual(
      (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?
        .intValue, PrivateStore.maximumFileBytes + 1)
    try PrivateStore.save(.initial, at: root)
  }
  func testValidSettingsRoundTripAndRecoveryIsExplicit() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var library = Library.initial
    library.materializeInstanceOptions()
    library.settings.size = 42
    try PrivateStore.save(library, at: root)
    XCTAssertEqual(try PrivateStore.load(at: root), library)
    XCTAssertThrowsError(try PrivateStore.recover(at: root.appendingPathComponent("missing")))
    XCTAssertEqual(try PrivateStore.load(at: root), library)
  }
  func testFutureSchemaAndDuplicateIdentifiersArePreserved() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("library.json")
    for variant in 0..<2 {
      var library = Library.initial
      if variant == 0 { library.schema = 99 } else { library.layout.append(library.layout[0]) }
      let data = try JSONEncoder().encode(library)
      try data.write(to: file)
      XCTAssertThrowsError(try PrivateStore.load(at: root))
      XCTAssertThrowsError(try PrivateStore.save(.initial, at: root))
      XCTAssertEqual(try Data(contentsOf: file), data)
    }
  }
}
