import Carbon
import XCTest

@testable import SelectionBarCore

final class ShortcutRecordingTests: XCTestCase {
  func testRecorderUsesPhysicalCodeAndOnlyUsefulGlobalModifiers() throws {
    let value = try ShortcutRecording.recorded(
      keyCode: 49,
      flags: CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskAlphaShift.rawValue)
    XCTAssertEqual(value, "control option 0x31")
    let combo = try KeyCombo.parse(value)
    XCTAssertEqual(combo.code, 49)
    XCTAssertEqual(
      combo.flags, CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue)
    XCTAssertThrowsError(
      try ShortcutRecording.recorded(keyCode: 0, flags: CGEventFlags.maskShift.rawValue))
    XCTAssertEqual(try ShortcutRecording.recorded(keyCode: 122, flags: 0), "0x7a")
  }
  @MainActor func testRecorderLabelsModifiersAndNamedKeys() {
    XCTAssertEqual(ShortcutRecording.label("control option 0x31"), "⌃⌥Space")
    XCTAssertEqual(ShortcutRecording.label("0x7a"), "F1")
    XCTAssertEqual(ShortcutRecording.label("invalid invalid"), "錄製快捷鍵")
  }
  func testPrimaryActionPlacementUsesPointerAndClampsAcrossDisplays() {
    let visible = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    let frame = Placement.frame(
      anchor: CGRect(x: -900, y: 500, width: 200, height: 20),
      size: CGSize(width: 400, height: 44), visible: visible, below: false, primaryOffset: 75,
      pointerX: -820)
    XCTAssertEqual(frame.minX, -895)
    XCTAssertEqual(frame.minX + 75, -820)
    let clamped = Placement.frame(
      anchor: CGRect(x: -1910, y: 1000, width: 1, height: 1),
      size: CGSize(width: 400, height: 44), visible: visible, below: false, primaryOffset: 200,
      pointerX: -1910)
    XCTAssertEqual(clamped.minX, visible.minX + 6)
    XCTAssertTrue(visible.contains(clamped))
  }
}
