import Carbon
import Foundation
import XCTest

@testable import SelectionBarCore

final class KeyboardLayoutTests: XCTestCase {
  private func source(_ id: String) throws -> TISInputSource {
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    let sources = TISCreateInputSourceList(filter, true).takeRetainedValue()
    guard CFArrayGetCount(sources) > 0, let first = CFArrayGetValueAtIndex(sources, 0) else {
      throw XCTSkip("System keyboard layout is absent: \(id)")
    }
    return Unmanaged<TISInputSource>.fromOpaque(first).takeUnretainedValue()
  }

  func testUSShiftedPunctuationNumericPadAndUnrepresentableInput() throws {
    let layout = try source("com.apple.keylayout.US")
    XCTAssertEqual(KeyboardLayout.resolve("A", in: layout), KeyCombo(code: 0, flags: 0))
    XCTAssertEqual(KeyboardLayout.resolve("+", in: layout), KeyCombo(code: 24, flags: 1 << 17))
    XCTAssertEqual(
      KeyboardLayout.resolve("/", in: layout, numericPad: true),
      KeyCombo(code: 75, flags: 1 << 21))
    XCTAssertEqual(
      KeyboardLayout.resolve("1", in: layout, numericPad: true),
      KeyCombo(code: 83, flags: 1 << 21))
    XCTAssertNil(KeyboardLayout.resolve("😀", in: layout))
    XCTAssertNil(KeyboardLayout.resolve("aa", in: layout))
    XCTAssertNil(KeyboardLayout.resolve("", in: layout))
  }

  func testFrenchAndGermanLayoutsUseTheirActualPhysicalPositions() throws {
    let french = try source("com.apple.keylayout.French")
    XCTAssertEqual(KeyboardLayout.resolve("a", in: french)?.code, 12)
    XCTAssertEqual(KeyboardLayout.resolve("q", in: french)?.code, 0)
    let german = try source("com.apple.keylayout.German")
    XCTAssertEqual(KeyboardLayout.resolve("z", in: german)?.code, 16)
    XCTAssertEqual(KeyboardLayout.resolve("y", in: german)?.code, 6)
    // Resolving another source invalidates the cache without changing the user's source.
    XCTAssertEqual(KeyboardLayout.resolve("a", in: french)?.code, 12)
  }

  func testUnicodeLegendsKeepAccentsAndNormalizeCanonicalSpelling() throws {
    let french = try source("com.apple.keylayout.French")
    let accented = try XCTUnwrap(KeyboardLayout.resolve("é", in: french))
    XCTAssertEqual(accented, KeyboardLayout.resolve("e\u{301}", in: french))
    XCTAssertNotEqual(accented.code, KeyboardLayout.resolve("e", in: french)?.code)
  }
}
