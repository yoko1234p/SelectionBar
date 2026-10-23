import AppKit
import CommonCrypto
import CoreServices
import CryptoKit
import Foundation
import JavaScriptCore
import Security

/// Passive macOS helpers exposed by the documented extension API. No file or network access.
public enum JavaScriptNativeExtras {
  public static func install(in context: JSContext) {
    let bridge: @convention(block) (String, String) -> String = { operation, raw in
      do {
        guard raw.utf8.count <= 48 * 1024 * 1024 else {
          throw LibraryError.invalid("Passive utility input exceeds 48 MiB.")
        }
        let input = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] ?? [:]
        let result = try perform(operation, input: input)
        return String(
          decoding: try JSONSerialization.data(withJSONObject: ["value": result]), as: UTF8.self)
      } catch {
        return String(
          decoding: (try? JSONSerialization.data(withJSONObject: [
            "error": error.localizedDescription
          ])) ?? Data(), as: UTF8.self)
      }
    }
    context.setObject(bridge, forKeyedSubscript: "__nativeExtras" as NSString)
  }

  private static func perform(_ operation: String, input: [String: Any]) throws -> Any {
    switch operation {
    case "locale":
      let locale = Locale.autoupdatingCurrent
      return [
        "localeIdentifier": locale.identifier,
        "languageCode": locale.language.languageCode?.identifier ?? "",
        "regionCode": locale.region?.identifier ?? "",
        "decimalSeparator": locale.decimalSeparator ?? "",
        "groupingSeparator": locale.groupingSeparator ?? "",
        "currencyCode": locale.currency?.identifier ?? "",
        "currencySymbol": locale.currencySymbol ?? "",
      ]
    case "timeZone":
      let zone = TimeZone.autoupdatingCurrent
      return [
        "identifier": zone.identifier, "abbreviation": zone.abbreviation() ?? "",
        "secondsOffset": zone.secondsFromGMT(), "daylightSaving": zone.isDaylightSavingTime(),
      ] as [String: Any]
    case "dictionary":
      let text = input["text"] as? String ?? ""
      guard !text.isEmpty else { return NSNull() }
      if let definition = DCSCopyTextDefinition(
        nil, text as CFString, CFRange(location: 0, length: (text as NSString).length))?
        .takeRetainedValue()
      {
        return definition as String
      }
      return NSNull()
    case "spellingLanguages", "preferredSpellingLanguages", "checkSpelling", "spellingGuesses":
      return try onMain { try spelling(operation, input: input) }
    case "richString":
      return try onMain { try richString(input) }
    case "uuid": return UUID().uuidString.lowercased()
    case "random":
      guard let count = input["count"] as? Int, (0...1_048_576).contains(count) else {
        throw LibraryError.invalid("Random byte request exceeds 1 MiB.")
      }
      return try randomData(count: count).base64EncodedString()
    case "randomUniform":
      let max = (input["max"] as? NSNumber)?.uint32Value ?? 0
      let range = UInt64(max) + 1
      let bound = (UInt64(1) << 32) / range * range
      while true {
        let data = try randomData(count: 4)
        let sample = data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        if sample < bound { return NSNumber(value: sample % range) }
      }
    case "hash", "hmac":
      guard let base64 = input["data"] as? String, base64.utf8.count <= 44_739_248,
        let data = Data(base64Encoded: base64), data.count <= 32 * 1024 * 1024
      else {
        throw LibraryError.invalid("Invalid hash input.")
      }
      let algorithm = input["algorithm"] as? String ?? ""
      let pairs: [String: (CCHmacAlgorithm, Int)] = [
        "md5": (CCHmacAlgorithm(kCCHmacAlgMD5), Int(CC_MD5_DIGEST_LENGTH)),
        "sha1": (CCHmacAlgorithm(kCCHmacAlgSHA1), Int(CC_SHA1_DIGEST_LENGTH)),
        "sha224": (CCHmacAlgorithm(kCCHmacAlgSHA224), Int(CC_SHA224_DIGEST_LENGTH)),
        "sha256": (CCHmacAlgorithm(kCCHmacAlgSHA256), Int(CC_SHA256_DIGEST_LENGTH)),
        "sha384": (CCHmacAlgorithm(kCCHmacAlgSHA384), Int(CC_SHA384_DIGEST_LENGTH)),
        "sha512": (CCHmacAlgorithm(kCCHmacAlgSHA512), Int(CC_SHA512_DIGEST_LENGTH)),
      ]
      guard let pair = pairs[algorithm] else {
        throw LibraryError.invalid("Unsupported hash algorithm: \(algorithm)")
      }
      if operation == "hash", algorithm == "md5" {
        return Data(Insecure.MD5.hash(data: data)).base64EncodedString()
      }
      var digest = Data(count: pair.1)
      if operation == "hmac" {
        guard let string = input["key"] as? String, string.utf8.count <= 44_739_248,
          let key = Data(base64Encoded: string), key.count <= 32 * 1024 * 1024
        else { throw LibraryError.invalid("Invalid HMAC key.") }
        digest.withUnsafeMutableBytes { output in
          key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { bytes in
              CCHmac(
                pair.0, keyBytes.baseAddress, key.count, bytes.baseAddress, data.count,
                output.baseAddress)
            }
          }
        }
      } else {
        _ = digest.withUnsafeMutableBytes { output in
          data.withUnsafeBytes { bytes in
            let count = CC_LONG(data.count)
            switch algorithm {
            case "sha1":
              return CC_SHA1(
                bytes.baseAddress, count, output.bindMemory(to: UInt8.self).baseAddress)
            case "sha224":
              return CC_SHA224(
                bytes.baseAddress, count, output.bindMemory(to: UInt8.self).baseAddress)
            case "sha256":
              return CC_SHA256(
                bytes.baseAddress, count, output.bindMemory(to: UInt8.self).baseAddress)
            case "sha384":
              return CC_SHA384(
                bytes.baseAddress, count, output.bindMemory(to: UInt8.self).baseAddress)
            default:
              return CC_SHA512(
                bytes.baseAddress, count, output.bindMemory(to: UInt8.self).baseAddress)
            }
          }
        }
      }
      return digest.base64EncodedString()
    default: throw LibraryError.invalid("Unknown passive utility: \(operation)")
    }
  }

  private static func randomData(count: Int) throws -> Data {
    guard count > 0 else { return Data() }
    var data = Data(count: count)
    let status = data.withUnsafeMutableBytes {
      SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
    }
    guard status == errSecSuccess else {
      throw LibraryError.invalid("Secure random source unavailable (\(status)).")
    }
    return data
  }

  private static func onMain<T>(_ body: () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try body() }
    return try DispatchQueue.main.sync(execute: body)
  }

  private static func spelling(_ operation: String, input: [String: Any]) throws -> Any {
    let checker = NSSpellChecker.shared
    let available: [String] = checker.availableLanguages
    if operation == "spellingLanguages" {
      return available.map {
        ["code": $0, "name": Locale.autoupdatingCurrent.localizedString(forIdentifier: $0) ?? $0]
      }
    }
    if operation == "preferredSpellingLanguages" {
      let preferred: [String] = Locale.preferredLanguages.map {
        $0.replacingOccurrences(of: "-", with: "_")
      }
      var matches: [String] = []
      for candidate in available {
        for language in preferred {
          if language == candidate || language.hasPrefix(candidate + "_")
            || candidate.hasPrefix(language + "_")
          {
            matches.append(candidate)
            break
          }
        }
      }
      return matches
    }
    let language = input["language"] as? String ?? ""
    guard available.contains(language) else {
      throw LibraryError.invalid("Unavailable spelling language: \(language)")
    }
    let text = input["text"] as? String ?? ""
    let range = checker.checkSpelling(
      of: text, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0,
      wordCount: nil)
    if operation == "checkSpelling" { return range.location == NSNotFound }
    guard range.location == 0, range.length == (text as NSString).length else { return [String]() }
    let guesses =
      checker.guesses(forWordRange: range, in: text, language: language, inSpellDocumentWithTag: 0)
      ?? []
    return Array(guesses.prefix(max(0, input["limit"] as? Int ?? guesses.count)))
  }

  private static func richString(_ input: [String: Any]) throws -> [String: String] {
    guard let source = input["source"] as? String, source.utf8.count <= 8 * 1024 * 1024 else {
      throw LibraryError.invalid("Rich text input exceeds 8 MiB.")
    }
    let format = input["format"] as? String ?? "rtf"
    let value: NSAttributedString
    switch format {
    case "rtf":
      value = try NSAttributedString(
        data: Data(source.utf8), options: [.documentType: NSAttributedString.DocumentType.rtf],
        documentAttributes: nil)
    case "html": value = try SafeRichTextHTML.parse(source)
    default: throw LibraryError.invalid("Unsupported rich text format: \(format)")
    }
    let range = NSRange(location: 0, length: value.length)
    let rtf = try value.data(
      from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    let html = try value.data(
      from: range,
      documentAttributes: [
        .documentType: NSAttributedString.DocumentType.html,
        .characterEncoding: String.Encoding.utf8.rawValue,
      ])
    guard let rich = String(data: rtf, encoding: .utf8) ?? String(data: rtf, encoding: .isoLatin1),
      let markup = String(data: html, encoding: .utf8)
    else { throw LibraryError.invalid("macOS could not serialize rich text.") }
    return ["rtf": rich, "html": markup, "text": value.string]
  }
}
