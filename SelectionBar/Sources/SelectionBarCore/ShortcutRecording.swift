import Foundation

public enum ShortcutRecording {
  public static func recorded(keyCode: UInt16, flags: UInt64) throws -> String {
    let flags = flags & 0x1e0000
    let functions: Set<UInt16> = [
      122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]
    guard flags & 0x1c0000 != 0 || functions.contains(keyCode) else {
      throw LibraryError.invalid(L10n.text("請加上 ⌘、⌃ 或 ⌥ 修飾鍵，或選擇 F1–F20。"))
    }
    let modifiers: [(String, UInt64)] = [
      ("control", 1 << 18), ("option", 1 << 19), ("shift", 1 << 17), ("command", 1 << 20),
    ]
    return (modifiers.filter { flags & $0.1 != 0 }.map(\.0) + ["0x" + String(keyCode, radix: 16)])
      .joined(separator: " ")
  }
  public static func label(_ value: String) -> String {
    guard let combo = try? KeyCombo.parse(value) else { return L10n.text("錄製快捷鍵") }
    return modifierLabel(combo.flags) + KeyboardLayout.legend(for: combo.code)
  }
  public static func modifierLabel(_ flags: UInt64) -> String {
    [(UInt64(1 << 18), "⌃"), (1 << 19, "⌥"), (1 << 17, "⇧"), (1 << 20, "⌘")]
      .filter { flags & $0.0 != 0 }.map(\.1).joined()
  }
}
