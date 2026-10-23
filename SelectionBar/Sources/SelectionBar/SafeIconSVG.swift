import AppKit
import ImageIO

/// Converts passive SVG into a bounded, self-contained document before AppKit sees it.
/// In particular, native SVG decoding must never receive an external resource reference.
enum SafeIconSVG {
  struct Document {
    let data: Data
    let size: CGSize
    let hasColor: Bool
  }

  static func document(_ data: Data) -> Document? { Validator.parse(data) }

  @MainActor static func image(_ document: Document) -> NSImage? {
    guard let image = NSImage(data: document.data), image.isValid else { return nil }
    image.size = document.size
    return image
  }

  private final class Validator: NSObject, XMLParserDelegate {
    static let elements: Set<String> = [
      "svg", "g", "defs", "symbol", "use", "title", "desc", "path", "rect", "circle",
      "ellipse", "line", "polyline", "polygon", "linearGradient", "radialGradient", "stop",
      "clipPath", "mask", "pattern", "image", "filter", "feBlend", "feColorMatrix",
      "feComponentTransfer", "feFuncR", "feFuncG", "feFuncB", "feFuncA", "feComposite",
      "feFlood", "feGaussianBlur", "feMerge", "feMergeNode", "feMorphology", "feOffset",
      "feTile", "feDropShadow",
    ]
    static let styles: Set<String> = [
      "color", "fill", "fill-rule", "fill-opacity", "stroke", "stroke-width", "stroke-opacity",
      "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-dasharray",
      "stroke-dashoffset", "opacity", "display", "visibility", "clip-path", "clip-rule", "mask",
      "filter", "stop-color", "stop-opacity", "flood-color", "flood-opacity", "color-interpolation",
      "color-interpolation-filters", "vector-effect", "paint-order", "isolation", "mix-blend-mode",
      "mask-type", "shape-rendering", "image-rendering", "overflow",
    ]
    static let attributes: Set<String> = styles.union([
      "xmlns", "xmlns:xlink", "version", "id", "viewBox", "preserveAspectRatio", "width", "height",
      "x", "y", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry", "d", "points",
      "transform", "gradientTransform", "gradientUnits", "spreadMethod", "offset", "fx", "fy", "fr",
      "clipPathUnits", "maskUnits", "maskContentUnits", "patternUnits", "patternContentUnits",
      "patternTransform", "href", "xlink:href", "filterUnits", "primitiveUnits", "in", "in2",
      "result",
      "mode", "type", "values", "operator", "k1", "k2", "k3", "k4", "stdDeviation", "dx", "dy",
      "radius", "slope", "intercept", "amplitude", "exponent", "tableValues", "style",
    ])
    static let numberExpression = try! NSRegularExpression(
      pattern: #"[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?"#)
    struct Node {
      var children: [Int] = []
      var references: [String] = []
      var weight = 1
    }
    var nodes: [Node] = []
    var stack: [(name: String, index: Int)] = []
    var identifiers: [String: Int] = [:]
    var output = ""
    var valid = true
    var hasColor = false
    var size = CGSize.zero
    var textBytes = 0
    var embeddedBytes = 0

    static func parse(_ data: Data) -> Document? {
      guard !data.isEmpty, data.count <= 512 * 1024,
        let text = String(data: data, encoding: .utf8),
        !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
        !text.localizedCaseInsensitiveContains("<!ENTITY")
      else { return nil }
      let validator = Validator()
      let parser = XMLParser(data: data)
      parser.shouldResolveExternalEntities = false
      parser.externalEntityResolvingPolicy = .never
      parser.delegate = validator
      guard parser.parse(), validator.valid, validator.stack.isEmpty, !validator.nodes.isEmpty,
        validator.referencesAreBounded()
      else { return nil }
      return Document(
        data: Data(validator.output.utf8), size: validator.size, hasColor: validator.hasColor)
    }

    func parser(
      _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
      qualifiedName: String?, attributes raw: [String: String]
    ) {
      guard valid, Self.elements.contains(name), nodes.count < 2048, stack.count < 32,
        raw.count <= 64, raw.keys.allSatisfy(Self.attributes.contains)
      else {
        fail(parser)
        return
      }
      let index = nodes.count
      nodes.append(Node())
      if name.hasPrefix("fe") { nodes[index].weight = 32 }
      if name == "filter" || name == "image" { nodes[index].weight = 16 }
      if name == "pattern" { nodes[index].weight = 128 }
      if let parent = stack.last {
        nodes[parent.index].children.append(index)
      } else {
        guard index == 0, name == "svg", let dimensions = dimensions(raw) else {
          fail(parser)
          return
        }
        size = dimensions
      }
      var attributes = raw
      if let style = attributes.removeValue(forKey: "style") {
        for declaration in style.split(separator: ";") {
          let parts = declaration.split(
            separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
          guard parts.count == 2 else {
            fail(parser)
            return
          }
          let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
          guard Self.styles.contains(key) else {
            fail(parser)
            return
          }
          attributes[key] = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
      }
      // Always provide bounded intrinsic dimensions; Iconify commonly sends height="1em".
      if index == 0 {
        attributes["width"] = String(Double(size.width))
        attributes["height"] = String(Double(size.height))
        attributes["xmlns"] = "http://www.w3.org/2000/svg"
      }
      for (key, value) in attributes {
        guard value.utf8.count <= 256 * 1024, validate(key, value, element: name, node: index)
        else {
          fail(parser)
          return
        }
      }
      output += "<" + name
      for key in attributes.keys.sorted() {
        output += " " + key + "=\"" + escape(attributes[key]!) + "\""
      }
      output += ">"
      stack.append((name, index))
    }

    func parser(
      _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?
    ) {
      guard stack.last?.name == name else {
        fail(parser)
        return
      }
      stack.removeLast()
      output += "</" + name + ">"
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
      textBytes += string.utf8.count
      guard textBytes <= 16 * 1024 else {
        fail(parser)
        return
      }
      guard
        stack.last?.name == "title" || stack.last?.name == "desc"
          || string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        fail(parser)
        return
      }
      output += escape(string)
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) { fail(parser) }
    func parser(
      _ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?
    ) { fail(parser) }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?)
      -> Data?
    {
      fail(parser)
      return nil
    }
    func fail(_ parser: XMLParser) {
      valid = false
      parser.abortParsing()
    }

    func validate(_ key: String, _ raw: String, element: String, node: Int) -> Bool {
      let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard
        !value.unicodeScalars.contains(where: {
          $0.value < 32 && $0 != "\n" && $0 != "\r" && $0 != "\t"
        })
      else { return false }
      if key == "xmlns" { return value == "http://www.w3.org/2000/svg" }
      if key == "xmlns:xlink" { return value == "http://www.w3.org/1999/xlink" }
      if key == "id" {
        guard Self.identifier(value), identifiers[value] == nil else { return false }
        identifiers[value] = node
        return true
      }
      if key == "href" || key == "xlink:href" {
        if value.hasPrefix("#"), Self.identifier(String(value.dropFirst())) {
          nodes[node].references.append(String(value.dropFirst()))
          return true
        }
        guard element == "image" else { return false }
        return embeddedImage(value)
      }
      let lower = value.lowercased()
      // No stylesheet evaluation, CSS escapes, variables, external URI or executable syntax.
      guard !value.contains("\\"), !value.contains("@"), !lower.contains("expression"),
        !lower.contains("var("), !lower.contains("javascript:"), !lower.contains("://"),
        !lower.contains("data:"), !lower.contains("file:"), !lower.contains("!important")
      else { return false }
      if lower.contains("url") {
        guard ["fill", "stroke", "clip-path", "mask", "filter"].contains(key),
          let match = value.range(
            of: #"^url\(\s*['\"]?#([A-Za-z_][A-Za-z0-9_.:-]{0,127})['\"]?\s*\)$"#,
            options: .regularExpression)
        else { return false }
        let reference = String(value[match]).replacingOccurrences(
          of: #"^url\(\s*['\"]?#|['\"]?\s*\)$"#, with: "", options: .regularExpression)
        nodes[node].references.append(reference)
        return true
      }
      if ["fill", "stroke", "color", "stop-color", "flood-color"].contains(key) {
        guard
          value.range(
            of: #"^[A-Za-z]+$|^#[0-9a-fA-F]{3,8}$|^(rgb|rgba|hsl|hsla)\([0-9eE.,%+\-\s/]+\)$"#,
            options: .regularExpression) != nil
        else { return false }
        if !stack.contains(where: { ["mask", "clipPath"].contains($0.name) }),
          !["none", "currentcolor", "inherit", "black", "#000", "#000000", "transparent"].contains(
            lower)
        {
          hasColor = true
        }
      }
      // Bound geometric/filter complexity before passing values into the native decoder.
      if ["d", "points", "transform", "gradientTransform", "patternTransform"].contains(key) {
        guard value.count <= 128 * 1024,
          value.filter({ $0 == "," || $0.isWhitespace }).count <= 32_768
        else { return false }
        nodes[node].weight += max(1, value.utf8.count / 8)
      }
      let numbers = Self.numberExpression.matches(
        in: value, range: NSRange(value.startIndex..., in: value)
      ).compactMap {
        Range($0.range, in: value).flatMap { Double(value[$0]) }
      }
      guard numbers.count <= 32_768, numbers.allSatisfy({ $0.isFinite && abs($0) <= 1e7 }) else {
        return false
      }
      if ["stdDeviation", "radius"].contains(key) {
        let limit = min(128, Double(min(size.width, size.height)) * 4)
        guard numbers.count <= 2, numbers.allSatisfy({ (0...limit).contains($0) }) else {
          return false
        }
      }
      if ["filter", "mask", "pattern"].contains(element),
        ["x", "y", "width", "height"].contains(key)
      {
        let limit = value.hasSuffix("%") ? 800 : Double(max(size.width, size.height)) * 8
        guard numbers.count == 1, abs(numbers[0]) <= limit else { return false }
        if element == "pattern", ["width", "height"].contains(key) {
          let minimum = value.hasSuffix("%") ? 1 : Double(min(size.width, size.height)) / 256
          guard numbers[0] >= minimum else { return false }
        }
      }
      return value.range(
        of: #"(?i)(?:^|[\s,(])(?:nan|infinity|inf)(?:$|[\s,)])"#, options: .regularExpression)
        == nil
    }

    func dimensions(_ attributes: [String: String]) -> CGSize? {
      let values: [Double]
      if let box = attributes["viewBox"] {
        let parts = box.split(whereSeparator: { $0.isWhitespace || $0 == "," })
        guard parts.count == 4 else { return nil }
        values = parts.compactMap { Double($0) }
        guard values.count == 4, values.allSatisfy({ $0.isFinite && abs($0) <= 1e7 }) else {
          return nil
        }
      } else {
        func length(_ name: String) -> Double? {
          let value = attributes[name] ?? ""
          return Double(value.hasSuffix("px") ? String(value.dropLast(2)) : value)
        }
        guard let width = length("width"), let height = length("height") else { return nil }
        values = [0, 0, width, height]
      }
      guard values[2].isFinite, values[3].isFinite, (0.001...4096).contains(values[2]),
        (0.001...4096).contains(values[3]), (0.01...100).contains(values[2] / values[3])
      else { return nil }
      return CGSize(width: values[2], height: values[3])
    }

    func embeddedImage(_ source: String) -> Bool {
      guard embeddedBytes <= 512 * 1024, let comma = source.firstIndex(of: ","),
        ["data:image/png;base64", "data:image/jpeg;base64"].contains(String(source[..<comma])),
        let data = Data(base64Encoded: String(source[source.index(after: comma)...])),
        data.count <= 256 * 1024,
        let image = CGImageSourceCreateWithData(data as CFData, nil),
        ["public.png", "public.jpeg"].contains(CGImageSourceGetType(image) as String? ?? ""),
        let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int,
        (1...1024).contains(width), (1...1024).contains(height)
      else { return false }
      embeddedBytes += data.count
      if !stack.contains(where: { ["mask", "clipPath"].contains($0.name) }) { hasColor = true }
      return embeddedBytes <= 512 * 1024
    }

    static func identifier(_ value: String) -> Bool {
      value.range(of: #"^[A-Za-z_][A-Za-z0-9_.:-]{0,127}$"#, options: .regularExpression) != nil
    }

    /// Count expanded use/gradient/clip dependencies, not just XML nodes, to reject cycles and use bombs.
    func referencesAreBounded() -> Bool {
      var visiting = Set<Int>()
      var totals: [Int: (count: Int, height: Int)] = [:]
      func cost(_ index: Int, depth: Int) -> Int? {
        guard depth <= 64, !visiting.contains(index) else { return nil }
        if let value = totals[index] { return depth + value.height <= 64 ? value.count : nil }
        visiting.insert(index)
        defer { visiting.remove(index) }
        var total = nodes[index].weight
        guard total <= 16_384 else { return nil }
        var height = 0
        var children = nodes[index].children
        for reference in nodes[index].references {
          guard let target = identifiers[reference] else { return nil }
          children.append(target)
        }
        for child in children {
          guard let value = cost(child, depth: depth + 1), total <= 16_384 - value else {
            return nil
          }
          total += value
          height = max(height, (totals[child]?.height ?? 0) + 1)
        }
        totals[index] = (total, height)
        return total
      }
      return cost(0, depth: 0) != nil
    }

    func escape(_ value: String) -> String {
      value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
  }
}
