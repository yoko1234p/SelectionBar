import Foundation
import SQLite3
import XCTest

@testable import SelectionBarCore

final class SQLiteReaderTests: XCTestCase {
  func testPrepareAndPartialStepFailuresNeverReturnDefaultsOrPartialRows() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    var writer: OpaquePointer?
    XCTAssertEqual(sqlite3_open(file.path, &writer), SQLITE_OK)
    XCTAssertEqual(
      sqlite3_exec(
        writer, "CREATE TABLE fixture(value INTEGER); INSERT INTO fixture VALUES(1);", nil, nil, nil
      ), SQLITE_OK)
    sqlite3_close(writer)
    let before = try Data(contentsOf: file)
    let reader = try ReadOnlyDatabase(file)
    XCTAssertThrowsError(try reader.query("SELECT value FROM missing_fixture")) { error in
      let failure = error as? SQLiteReadFailure
      XCTAssertEqual(failure?.phase, "prepare")
      XCTAssertEqual(failure?.primaryCode, SQLITE_ERROR)
    }
    XCTAssertThrowsError(
      try reader.query("SELECT 1 AS value UNION ALL SELECT abs(-9223372036854775808)")
    ) { error in
      let failure = error as? SQLiteReadFailure
      XCTAssertEqual(failure?.phase, "step")
      XCTAssertEqual(failure?.primaryCode, SQLITE_ERROR)
    }
    XCTAssertEqual(try reader.query("SELECT value FROM fixture").count, 1)
    XCTAssertEqual(try Data(contentsOf: file), before)
  }
  func testOpenFailureReportsOnlySafePhaseAndNumericCodes() {
    let path = URL(
      fileURLWithPath: "/nonexistent-selectionbar-fixture-" + UUID().uuidString + "/private.sqlite")
    XCTAssertThrowsError(try ReadOnlyDatabase(path)) { error in
      let failure = error as? SQLiteReadFailure
      XCTAssertEqual(failure?.phase, "open")
      XCTAssertEqual(failure?.primaryCode, SQLITE_CANTOPEN)
      XCTAssertFalse(error.localizedDescription.contains(path.path))
    }
  }
}
