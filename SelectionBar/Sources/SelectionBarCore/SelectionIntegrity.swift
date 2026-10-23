import CryptoKit
import Foundation

/// A selection is valid only while its observable source state is unchanged.
/// Digesting the document avoids retaining another copy of private text.
public struct SelectionIntegrity: Sendable {
  public var text: String
  public var range: NSRange?
  public var valueDigest: String?
  public init(text: String, range: NSRange?, value: String?) {
    self.text = text
    self.range = range
    self.valueDigest = Self.digest(value)
  }
  public func matches(text currentText: String?, range currentRange: NSRange?, value: String?)
    -> Bool
  {
    if let currentText, currentText != text { return false }
    if let range, let currentRange, range != currentRange { return false }
    if let valueDigest, let digest = Self.digest(value), digest != valueDigest { return false }
    // A missing AX attribute does not prove that a selection is safe to replace.
    return currentText != nil && (range == nil || currentRange != nil)
      || valueDigest != nil && Self.digest(value) == valueDigest && range != nil
        && currentRange != nil
  }
  private static func digest(_ value: String?) -> String? {
    guard let value, value.utf8.count <= 8 * 1024 * 1024 else { return nil }
    return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
