import AppKit
import SelectionBarCore
import XCTest

@testable import SelectionBar

final class PasteboardSnapshotTests: XCTestCase {
  @MainActor func testAggregateCaptureRejectsBeforeChangingPrivatePasteboard() throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let item = NSPasteboardItem()
    XCTAssertTrue(item.setData(Data(repeating: 1, count: 600), forType: .string))
    XCTAssertTrue(item.setData(Data(repeating: 2, count: 600), forType: .html))
    XCTAssertTrue(board.writeObjects([item]))
    let count = board.changeCount
    XCTAssertThrowsError(try PasteboardSnapshot(pasteboard: board, maximumBytes: 1000))
    XCTAssertEqual(board.changeCount, count)
    XCTAssertEqual(board.data(forType: .html), Data(repeating: 2, count: 600))
  }
  @MainActor func testSnapshotRestoresAllFormatsOnOwnedPasteboard() throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let first = NSPasteboardItem()
    first.setString("Synthetic 日本語", forType: .string)
    first.setString("<b>Synthetic</b>", forType: .html)
    let second = NSPasteboardItem()
    second.setData(
      Data([0, 1, 255]), forType: NSPasteboard.PasteboardType("dev.selectionbar.fixture"))
    XCTAssertTrue(board.writeObjects([first, second]))
    let snapshot = try PasteboardSnapshot(pasteboard: board)
    board.clearContents()
    board.setString("changed", forType: .string)
    try snapshot.restoreChecked()
    XCTAssertEqual(board.pasteboardItems?.count, 2)
    XCTAssertEqual(board.string(forType: .string), "Synthetic 日本語")
    XCTAssertEqual(
      board.pasteboardItems?[1].data(
        forType: NSPasteboard.PasteboardType("dev.selectionbar.fixture")), Data([0, 1, 255]))
  }
  @MainActor func testRichCopyReceiptDoesNotOverwriteAnInterveningCopy() throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    XCTAssertTrue(board.setString("previous", forType: .string))
    let previous = try PasteboardSnapshot(pasteboard: board)
    let before = board.changeCount
    board.clearContents()
    XCTAssertTrue(board.setString("first\r\nline", forType: .string))
    let receipt = try XCTUnwrap(
      RichCopyReceipt(pasteboard: board, previousChangeCount: before, expectedText: "first\nline"))
    XCTAssertTrue(receipt.isCurrent(on: board))
    board.clearContents()
    XCTAssertTrue(board.setString("user's newer copy", forType: .string))
    XCTAssertFalse(receipt.isCurrent(on: board))
    XCTAssertThrowsError(try previous.restoreChecked(expectedChangeCount: receipt.changeCount))
    XCTAssertEqual(board.string(forType: .string), "user's newer copy")
    XCTAssertNil(
      RichCopyReceipt(pasteboard: board, previousChangeCount: before, expectedText: "first\nline"))
  }
}
