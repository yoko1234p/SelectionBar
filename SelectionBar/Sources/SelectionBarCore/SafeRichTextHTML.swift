import AppKit
import Foundation

/// Text-only HTML importer: parses markup without WebKit, resource loaders or external entities.
enum SafeRichTextHTML {
  static func parse(_ source: String) throws -> NSAttributedString {
    guard source.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
      source.range(of: "<!ENTITY", options: .caseInsensitive) == nil
    else { throw LibraryError.invalid("Rich text document declarations are unsupported.") }
    let parser = XMLParser(
      data: Data(("<selectionbar-root>" + source + "</selectionbar-root>").utf8))
    parser.shouldResolveExternalEntities = false
    parser.externalEntityResolvingPolicy = .never
    let reader = Reader()
    parser.delegate = reader
    guard parser.parse(), reader.failure == nil else {
      throw LibraryError.invalid(reader.failure ?? "Invalid normalized rich text markup.")
    }
    return reader.result
  }

  private final class Reader: NSObject, XMLParserDelegate {
    let result = NSMutableAttributedString(string: "")
    var failure: String?
    private var stack: [[NSAttributedString.Key: Any]] = []
    private var ignoredDepth: Int?
    private var preDepth = 0
    private var nodes = 0
    private var lists: [(ordered: Bool, count: Int)] = []
    private let blocked: Set<String> = [
      "script", "style", "iframe", "object", "embed", "svg", "math", "head",
    ]
    private let blocks: Set<String> = [
      "p", "div", "section", "article", "blockquote", "pre", "h1", "h2", "h3", "h4", "h5", "h6",
      "tr", "ul", "ol", "li",
    ]
    private var attributes: [NSAttributedString.Key: Any] {
      stack.last ?? [.font: NSFont.systemFont(ofSize: 13)]
    }
    private func append(_ string: String, attributes: [NSAttributedString.Key: Any]? = nil) {
      result.append(NSAttributedString(string: string, attributes: attributes ?? self.attributes))
    }
    private func lineBreak() {
      if result.length > 0, !result.string.hasSuffix("\n") { append("\n") }
    }
    func parser(
      _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
      qualifiedName: String?, attributes source: [String: String]
    ) {
      nodes += 1
      guard nodes <= 100_000, stack.count < 256 else {
        failure = "Rich text markup exceeds parsing limits."
        parser.abortParsing()
        return
      }
      let tag = name.lowercased()
      var current = attributes
      stack.append(current)
      if ignoredDepth != nil { return }
      if blocked.contains(tag) {
        ignoredDepth = stack.count
        return
      }
      if blocks.contains(tag) { lineBreak() }
      if tag == "br" { append("\n") }
      if tag == "pre" { preDepth += 1 }
      if tag == "ul" || tag == "ol" { lists.append((tag == "ol", 0)) }
      if tag == "li", !lists.isEmpty {
        lists[lists.count - 1].count += 1
        let item = lists[lists.count - 1]
        append(
          String(repeating: "\t", count: lists.count - 1)
            + (item.ordered ? "\(item.count). " : "• "))
      }
      var font = current[.font] as? NSFont ?? .systemFont(ofSize: 13)
      if ["code", "pre", "kbd", "samp"].contains(tag) {
        font = .monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
      }
      if tag.count == 2, tag.first == "h", let level = tag.last?.wholeNumberValue,
        (1...6).contains(level)
      {
        font = .boldSystemFont(ofSize: CGFloat(28 - level * 2))
      }
      if tag == "b" || tag == "strong" {
        font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
      }
      if tag == "i" || tag == "em" {
        font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
      }
      if tag == "u" { current[.underlineStyle] = NSUnderlineStyle.single.rawValue }
      if ["s", "strike", "del"].contains(tag) {
        current[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
      }
      if tag == "a", let href = source["href"], let url = URL(string: href) { current[.link] = url }
      if let value = source["color"], let color = color(value) { current[.foregroundColor] = color }
      if let family = source["face"], let chosen = NSFont(name: family, size: font.pointSize) {
        font = chosen
      }
      for declaration in (source["style"] ?? "").split(separator: ";") {
        let pair = declaration.split(separator: ":", maxSplits: 1).map {
          $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard pair.count == 2 else { continue }
        switch pair[0].lowercased() {
        case "font-weight":
          if pair[1] == "bold" || (Int(pair[1]) ?? 0) >= 600 {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
          }
        case "font-style":
          if pair[1] == "italic" || pair[1] == "oblique" {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
          }
        case "font-size":
          let number = pair[1].prefix { $0.isNumber || $0 == "." }
          if let size = Double(number), size.isFinite, (1...512).contains(size) {
            font = NSFontManager.shared.convert(font, toSize: CGFloat(size))
          }
        case "color": if let value = color(pair[1]) { current[.foregroundColor] = value }
        case "background-color": if let value = color(pair[1]) { current[.backgroundColor] = value }
        case "text-decoration":
          if pair[1].contains("underline") {
            current[.underlineStyle] = NSUnderlineStyle.single.rawValue
          }
          if pair[1].contains("line-through") {
            current[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
          }
        default: break
        }
      }
      current[.font] = font
      stack[stack.count - 1] = current
    }
    func parser(
      _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?
    ) {
      guard !stack.isEmpty else { return }
      let tag = name.lowercased()
      if let ignoredDepth {
        if stack.count == ignoredDepth { self.ignoredDepth = nil }
        stack.removeLast()
        return
      }
      if tag == "pre" { preDepth = max(0, preDepth - 1) }
      if tag == "ul" || tag == "ol", !lists.isEmpty { lists.removeLast() }
      if tag == "td" || tag == "th" { append("\t") }
      if blocks.contains(tag) { lineBreak() }
      stack.removeLast()
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
      guard ignoredDepth == nil else { return }
      var text =
        preDepth > 0
        ? string
        : string.replacingOccurrences(
          of: "[\\t\\n\\r\\f ]+", with: " ", options: .regularExpression)
      if preDepth == 0, text.hasPrefix(" "),
        result.string.hasSuffix(" ") || result.string.hasSuffix("\n")
      {
        text.removeFirst()
      }
      append(text)
    }
    func parser(_ parser: XMLParser, foundCDATA block: Data) {
      self.parser(parser, foundCharacters: String(decoding: block, as: UTF8.self))
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?)
      -> Data?
    { nil }
    private func color(_ raw: String) -> NSColor? {
      let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let names: [String: NSColor] = [
        "black": .black, "white": .white, "red": .red, "green": .green, "blue": .blue,
        "gray": .gray, "grey": .gray, "yellow": .yellow, "orange": .orange, "purple": .purple,
        "transparent": .clear,
      ]
      if let named = names[text] { return named }
      guard text.hasPrefix("#") else { return nil }
      var hex = String(text.dropFirst())
      if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
      guard [6, 8].contains(hex.count), let number = UInt64(hex, radix: 16) else { return nil }
      let hasAlpha = hex.count == 8
      let rgb = hasAlpha ? number >> 8 : number
      return NSColor(
        srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
        blue: CGFloat(rgb & 255) / 255, alpha: hasAlpha ? CGFloat(number & 255) / 255 : 1)
    }
  }
}
