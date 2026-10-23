import Carbon
import Foundation

/// Maps a printed key to the active layout without selecting an input source or sending events.
public enum KeyboardLayout {
  private struct Cache {
    let data: CFData
    let keyboardType: UInt32
    let normal: [String: KeyCombo]
    let numeric: [String: KeyCombo]
  }

  private static var cache: Cache?
  public static func legend(for code: UInt16) -> String {
    let special: [UInt16: String] = [
      36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦", 123: "←", 124: "→",
      125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
      122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
      100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14",
      113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
    if let label = special[code] { return label }
    _ = resolve("a")
    return cache?.normal.filter { $0.value.code == code && $0.value.flags == 0 }
      .keys.sorted().first?.uppercased() ?? "Key \(code)"
  }

  /// Call on the main thread. Hex codes and named nonprinting keys bypass this lookup.
  public static func resolve(_ character: String, numericPad: Bool = false) -> KeyCombo? {
    guard Thread.isMainThread, character.count == 1 else { return nil }
    if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
      TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) != nil
    {
      return resolve(character, in: source, numericPad: numericPad)
    }
    // An input method can omit layout data. Use the system's actual ASCII-capable
    // fallback layout rather than assuming the physical positions of a US keyboard.
    guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
    else { return nil }
    return resolve(character, in: source, numericPad: numericPad)
  }

  static func resolve(_ character: String, in source: TISInputSource, numericPad: Bool = false)
    -> KeyCombo?
  {
    guard Thread.isMainThread, character.count == 1,
      let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }
    let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
    guard CFDataGetLength(data) >= MemoryLayout<UCKeyboardLayout>.size else { return nil }
    let keyboardType = UInt32(LMGetKbdType())
    if cache?.keyboardType != keyboardType || cache.map({ !CFEqual($0.data, data) }) != false {
      cache = makeCache(data: data, keyboardType: keyboardType)
    }
    let key = folded(character)
    return numericPad ? cache?.numeric[key] : cache?.normal[key]
  }

  private static func folded(_ character: String) -> String {
    character.precomposedStringWithCanonicalMapping.lowercased(
      with: Locale(identifier: "en_US_POSIX"))
  }

  private static func makeCache(data: CFData, keyboardType: UInt32) -> Cache? {
    guard let bytes = CFDataGetBytePtr(data) else { return nil }
    let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
    let mainCodes = Array(UInt16(0)...50) + [93, 94]
    let numericCodes: [UInt16] = [
      65, 67, 69, 75, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92, 95,
    ]
    let modifiers: [(carbon: UInt32, flags: UInt64)] = [
      (0, 0), (UInt32(shiftKey), 1 << 17), (UInt32(optionKey), 1 << 19),
      (UInt32(shiftKey | optionKey), (1 << 17) | (1 << 19)),
    ]
    func mapping(_ codes: [UInt16], numeric: Bool) -> [String: KeyCombo] {
      var result: [String: KeyCombo] = [:]
      // Prefer the least-modified key; duplicate legends keep the first physical key.
      for modifier in modifiers {
        for code in codes {
          var deadState: UInt32 = 0
          var count = 0
          var output = [UniChar](repeating: 0, count: 16)
          let status = UCKeyTranslate(
            layout, code, UInt16(kUCKeyActionDown), modifier.carbon >> 8, keyboardType,
            OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadState, output.count, &count, &output)
          guard status == noErr, count > 0, count <= output.count else { continue }
          let string = String(utf16CodeUnits: output, count: count)
          guard string.count == 1,
            !string.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
          else { continue }
          let key = folded(string)
          if result[key] == nil {
            result[key] = KeyCombo(
              code: code, flags: modifier.flags | (numeric ? UInt64(1 << 21) : 0))
          }
        }
      }
      return result
    }
    return Cache(
      data: data, keyboardType: keyboardType, normal: mapping(mainCodes, numeric: false),
      numeric: mapping(numericCodes, numeric: true))
  }
}
