import AppKit
import CryptoKit
import Darwin
import ImageIO
import SelectionBarCore

/// Rendering of the documented PopClip icon specifier grammar.
/// https://www.popclip.app/dev/icons
@MainActor
enum ExtensionIcon {
  private static let cache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 128
    cache.totalCostLimit = 4 * 1024 * 1024
    return cache
  }()
  private static let maximumBytes = 2 * 1024 * 1024

  static func image(
    config: Value?, packageRoot: URL, size: CGFloat = 20,
    properties: [String: Value] = [:]
  ) -> NSImage? {
    guard case .string(let source) = config, source.utf8.count <= 3 * 1024 * 1024,
      size.isFinite, (8...128).contains(size), var spec = Spec(source)
    else { return nil }
    guard spec.apply(properties) else { return nil }
    var file: URL?
    var stamp = ""
    var iconify: SafeIconSVG.Document?
    if spec.base.hasPrefix("iconify:") {
      guard let identifier = IconifyIdentifier(spec.base),
        let document = IconifyAssets.shared.document(for: identifier)
      else { return nil }
      iconify = document
      stamp = SHA256.hash(data: document.data).map { String(format: "%02x", $0) }.joined()
    }
    if let name = spec.file {
      guard packageRoot.isFileURL,
        let url = try? Manifest.confinedFile(name, root: packageRoot),
        ["png", "svg"].contains(url.pathExtension.lowercased()),
        let metadata = try? url.resourceValues(forKeys: [
          .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
        ]), metadata.isRegularFile == true,
        let bytes = metadata.fileSize, (1...maximumBytes).contains(bytes)
      else { return nil }
      file = url
      stamp = "\(bytes):\(metadata.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }
    let propertyIdentity = spec.modifierIdentity
    let identity =
      source + "\0" + packageRoot.path + "\0\(size)\0" + stamp + "\0" + propertyIdentity
    let key =
      SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }
      .joined() as NSString
    if let image = cache.object(forKey: key) { return image }
    let base =
      iconify.flatMap { document in
        SafeIconSVG.image(document).map { Base.nativeSVG($0, document.hasColor) }
      }
      ?? load(spec, file: file)
    guard let base,
      let image = render(
        base, spec: spec, size: size,
        automaticColor: iconify?.hasColor ?? false)
    else {
      return nil
    }
    cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 16))
    return image
  }

  private struct Spec {
    enum Shape: String { case square, circle, search }
    var base: String
    var shape: Shape?
    var filled = false
    var strike = false
    var monospaced = false
    var flipX = false
    var flipY = false
    var preserveColor: Bool?
    var preserveAspect = false
    var moveX: CGFloat = 0
    var moveY: CGFloat = 0
    var scale: CGFloat = 1
    var rotation: CGFloat = 0
    var hasModifiers = false

    var modifierIdentity: String {
      [
        shape?.rawValue ?? "", String(filled), String(strike), String(monospaced), String(flipX),
        String(flipY), preserveColor.map(String.init) ?? "auto", String(preserveAspect),
        String(Double(moveX)), String(Double(moveY)), String(Double(scale)),
        String(Double(rotation)),
        String(hasModifiers),
      ].joined(separator: ":")
    }

    init?(_ source: String) {
      base = source.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !base.isEmpty else { return nil }
      while let boundary = base.firstIndex(where: { $0.isWhitespace }) {
        let word = String(base[..<boundary])
        let pair = word.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(pair[0])
        let value = pair.count == 2 ? String(pair[1]) : "1"
        let flag: Bool
        switch value {
        case "0": flag = false
        case "1": flag = true
        default: flag = false
        }
        if let enclosing = Shape(rawValue: name) {
          guard value == "0" || value == "1" else { return nil }
          if flag { shape = enclosing } else if shape == enclosing { shape = nil }
        } else if [
          "filled", "strike", "monospaced", "flip-x", "flip-y", "preserve-color", "preserve-aspect",
        ]
        .contains(name) {
          guard value == "0" || value == "1" else { return nil }
          switch name {
          case "filled": filled = flag
          case "strike": strike = flag
          case "monospaced": monospaced = flag
          case "flip-x": flipX = flag
          case "flip-y": flipY = flag
          case "preserve-color": preserveColor = flag
          default: preserveAspect = flag
          }
        } else if ["move-x", "move-y", "scale", "rotate"].contains(name) {
          guard pair.count == 2, let number = Double(value), number.isFinite,
            abs(number) <= 360_000
          else { return nil }
          switch name {
          case "move-x": moveX = CGFloat(number) / 100
          case "move-y": moveY = CGFloat(number) / 100
          case "scale":
            guard number >= 0, number <= 10_000 else { return nil }
            scale = CGFloat(number) / 100
          default: rotation = CGFloat(number.truncatingRemainder(dividingBy: 360))
          }
        } else {
          break
        }
        hasModifiers = true
        base = String(base[boundary...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
      }
    }

    var file: String? {
      if base.hasPrefix("file:") { return String(base.dropFirst(5)) }
      if !base.contains(":"),
        ["png", "svg"].contains((base as NSString).pathExtension.lowercased())
      {
        return base
      }
      return nil
    }

    mutating func apply(_ properties: [String: Value]) -> Bool {
      let names = [
        "preservecolor": "preserve-color", "preserveaspect": "preserve-aspect",
        "flipx": "flip-x", "flipy": "flip-y", "movex": "move-x", "movey": "move-y",
        "scale": "scale", "rotate": "rotate", "square": "square", "circle": "circle",
        "search": "search", "strike": "strike", "filled": "filled", "monospaced": "monospaced",
      ]
      var modifiers: [String] = []
      for key in properties.keys.sorted() {
        let normalized = key.lowercased().filter { $0 != " " && $0 != "-" }
        guard let name = names[normalized] else { continue }
        let value = properties[key]!
        if ["move-x", "move-y", "scale", "rotate"].contains(name) {
          guard case .number(let number) = value, number.isFinite else { return false }
          modifiers.append("\(name)=\(number)")
        } else {
          let flag: Bool
          switch value {
          case .bool(let bool): flag = bool
          case .number(let number) where number == 0 || number == 1: flag = number == 1
          default: return false
          }
          modifiers.append("\(name)=\(flag ? 1 : 0)")
        }
      }
      guard !modifiers.isEmpty else { return true }
      // Property values override modifiers written into the source string.
      var existing: [String] = []
      if let shape { existing.append(shape.rawValue) }
      for (name, flag) in [
        ("filled", filled), ("strike", strike), ("monospaced", monospaced),
        ("flip-x", flipX), ("flip-y", flipY), ("preserve-aspect", preserveAspect),
      ] where flag { existing.append(name) }
      if let preserveColor { existing.append("preserve-color=\(preserveColor ? 1 : 0)") }
      existing += [
        "move-x=\(moveX * 100)", "move-y=\(moveY * 100)", "scale=\(scale * 100)",
        "rotate=\(rotation)",
      ]
      guard var merged = Spec((existing + modifiers).joined(separator: " ") + " " + base) else {
        return false
      }
      merged.hasModifiers = true
      self = merged
      return true
    }
  }

  private enum Base {
    case bitmap(CGImage)
    case symbol(NSImage)
    case text(String)
    case svg(IconSVG)
    case nativeSVG(NSImage, Bool)
    var size: CGSize {
      switch self {
      case .bitmap(let image): return CGSize(width: image.width, height: image.height)
      case .symbol(let image): return image.size
      case .text: return CGSize(width: 1, height: 1)
      case .svg(let svg): return svg.bounds.size
      case .nativeSVG(let image, _): return image.size
      }
    }
    var isEmoji: Bool {
      guard case .text(let text) = self, text.count == 1 else { return false }
      return text.unicodeScalars.contains {
        $0.properties.isEmojiPresentation || $0.value == 0xFE0F
      }
    }
  }

  private static func load(_ spec: Spec, file: URL?) -> Base? {
    if let file {
      guard let data = readFile(file) else { return nil }
      return decode(data, svg: file.pathExtension.lowercased() == "svg")
    }
    if spec.base.hasPrefix("symbol:") {
      let name = String(spec.base.dropFirst(7))
      guard name.utf8.count <= 160,
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
      else { return nil }
      return .symbol(image)
    }
    if spec.base.hasPrefix("svg:") {
      return decode(Data(spec.base.dropFirst(4).utf8), svg: true)
    }
    if spec.base.hasPrefix("data:") {
      guard let comma = spec.base.firstIndex(of: ",") else { return nil }
      let header = String(spec.base[..<comma]).lowercased()
      let svg: Bool
      switch header {
      case "data:image/png", "data:image/png;base64": svg = false
      case "data:image/svg+xml", "data:image/svg+xml;base64": svg = true
      default: return nil
      }
      let body = String(spec.base[spec.base.index(after: comma)...])
      let data = header.hasSuffix(";base64") ? Data(base64Encoded: body) : percentData(body)
      guard let data else { return nil }
      return decode(data, svg: svg)
    }
    if spec.base.hasPrefix("iconify:") { return nil }
    let text = spec.base.hasPrefix("text:") ? String(spec.base.dropFirst(5)) : spec.base
    guard !text.isEmpty, text.count <= 3,
      !text.unicodeScalars.contains(where: {
        [.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
      })
    else { return nil }
    return .text(text)
  }

  private static func readFile(_ url: URL) -> Data? {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { return nil }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      info.st_size > 0, info.st_size <= maximumBytes,
      let data = try? handle.read(upToCount: maximumBytes + 1), data.count <= maximumBytes
    else { return nil }
    return data
  }

  private static func percentData(_ source: String) -> Data? {
    let bytes = Array(source.utf8)
    var output = Data()
    var index = 0
    func hex(_ byte: UInt8) -> UInt8? {
      switch byte {
      case 48...57: return byte - 48
      case 65...70: return byte - 55
      case 97...102: return byte - 87
      default: return nil
      }
    }
    while index < bytes.count {
      guard output.count < maximumBytes else { return nil }
      if bytes[index] == 37 {
        guard index + 2 < bytes.count, let a = hex(bytes[index + 1]), let b = hex(bytes[index + 2])
        else { return nil }
        output.append(a * 16 + b)
        index += 3
      } else {
        output.append(bytes[index])
        index += 1
      }
    }
    return output
  }

  private static func decode(_ data: Data, svg: Bool) -> Base? {
    guard !data.isEmpty, data.count <= maximumBytes else { return nil }
    if svg {
      guard let document = SafeIconSVG.document(data) else { return nil }
      // Retain the small CoreGraphics geometry path where it is sufficient.
      if let image = IconSVG(document.data) { return .svg(image) }
      return SafeIconSVG.image(document).map { .nativeSVG($0, document.hasColor) }
    }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetType(source) as String? == "public.png",
      let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = metadata[kCGImagePropertyPixelWidth] as? Int,
      let height = metadata[kCGImagePropertyPixelHeight] as? Int,
      (1...4096).contains(width), (1...4096).contains(height), width * height <= 16_777_216,
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 512,
          kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    else { return nil }
    return .bitmap(image)
  }

  private static func render(_ base: Base, spec: Spec, size: CGFloat, automaticColor: Bool)
    -> NSImage?
  {
    let ratio = base.size.width / max(0.001, base.size.height)
    let width = spec.preserveAspect ? size * min(4, max(0.25, ratio)) : size
    let canvas = NSSize(width: width, height: size)
    let pixelsWide = Int(ceil(width * 2))
    let pixelsHigh = Int(ceil(size * 2))
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let graphics = NSGraphicsContext(bitmapImageRep: bitmap)
    else { return nil }
    let context = graphics.cgContext
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.restoreGraphicsState() }
    context.scaleBy(x: CGFloat(pixelsWide) / width, y: CGFloat(pixelsHigh) / size)
    context.clear(CGRect(origin: .zero, size: canvas))
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.setStrokeColor(CGColor(gray: 0, alpha: 1))
    context.setLineWidth(max(1, size / 15))
    let color = spec.preserveColor ?? (automaticColor || (base.isEmoji && !spec.hasModifiers))
    var destination = CGRect(origin: .zero, size: canvas).insetBy(
      dx: size * 0.035, dy: size * 0.035)
    if let shape = spec.shape {
      let frame = CGRect(origin: .zero, size: canvas).insetBy(dx: size * 0.065, dy: size * 0.065)
      switch shape {
      case .square:
        context.addPath(
          CGPath(
            roundedRect: frame, cornerWidth: size * 0.08, cornerHeight: size * 0.08, transform: nil)
        )
        destination = frame.insetBy(dx: size * 0.15, dy: size * 0.15)
      case .circle:
        context.addEllipse(in: frame)
        destination = frame.insetBy(dx: size * 0.16, dy: size * 0.16)
      case .search:
        let circle = CGRect(
          x: width * 0.055, y: size * 0.28, width: width * 0.65, height: size * 0.65)
        context.addEllipse(in: circle)
        destination = circle.insetBy(dx: size * 0.12, dy: size * 0.12)
      }
      context.drawPath(using: spec.filled ? .fill : .stroke)
      if shape == .search {
        context.setLineCap(.round)
        context.setLineWidth(max(1.5, size * 0.12))
        context.move(to: CGPoint(x: width * 0.61, y: size * 0.33))
        context.addLine(to: CGPoint(x: width * 0.88, y: size * 0.08))
        context.strokePath()
      }
    }
    // AppKit text/symbol drawing chooses its own compositing operation. Render
    // the glyph to a bounded layer, then apply a filled shape's cutout once in
    // CoreGraphics so text, SF Symbols and bitmap icons behave consistently.
    guard
      let glyph = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let glyphGraphics = NSGraphicsContext(bitmapImageRep: glyph)
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = glyphGraphics
    let glyphContext = glyphGraphics.cgContext
    glyphContext.scaleBy(x: CGFloat(pixelsWide) / width, y: CGFloat(pixelsHigh) / size)
    glyphContext.clear(CGRect(origin: .zero, size: canvas))
    glyphContext.translateBy(
      x: destination.midX + spec.moveX * width, y: destination.midY - spec.moveY * size)
    glyphContext.rotate(by: spec.rotation * .pi / 180)
    glyphContext.scaleBy(
      x: spec.scale * (spec.flipX ? -1 : 1), y: spec.scale * (spec.flipY ? -1 : 1))
    destination.origin = CGPoint(x: -destination.width / 2, y: -destination.height / 2)
    draw(base, in: destination, monospaced: spec.monospaced, context: glyphContext)
    NSGraphicsContext.restoreGraphicsState()
    guard let glyphImage = glyph.cgImage else { return nil }
    context.saveGState()
    context.setBlendMode(spec.filled && spec.shape != nil && !color ? .destinationOut : .normal)
    context.draw(glyphImage, in: CGRect(origin: .zero, size: canvas))
    context.restoreGState()
    if spec.strike {
      context.setLineWidth(max(1.25, size * 0.09))
      context.setLineCap(.round)
      context.move(to: CGPoint(x: width * 0.10, y: size * 0.10))
      context.addLine(to: CGPoint(x: width * 0.90, y: size * 0.90))
      context.strokePath()
    }
    bitmap.size = canvas
    let image = NSImage(size: canvas)
    image.addRepresentation(bitmap)
    image.isTemplate = !color
    return image
  }

  private static func draw(_ base: Base, in rect: CGRect, monospaced: Bool, context: CGContext) {
    let size = base.size
    let scale = min(rect.width / max(0.001, size.width), rect.height / max(0.001, size.height))
    let fitted = CGRect(
      x: rect.midX - size.width * scale / 2, y: rect.midY - size.height * scale / 2,
      width: size.width * scale, height: size.height * scale)
    switch base {
    case .bitmap(let image): context.draw(image, in: fitted)
    case .symbol(let image):
      let configured =
        image.withSymbolConfiguration(.init(pointSize: rect.height, weight: .medium)) ?? image
      configured.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1)
    case .text(let text):
      var fontSize = rect.height * 0.90
      func attributes(_ points: CGFloat) -> [NSAttributedString.Key: Any] {
        [
          .font: monospaced
            ? NSFont.monospacedSystemFont(ofSize: points, weight: .semibold)
            : NSFont.systemFont(ofSize: points, weight: .semibold), .foregroundColor: NSColor.black,
        ]
      }
      var attrs = attributes(fontSize)
      var measured = (text as NSString).size(withAttributes: attrs)
      if measured.width > rect.width {
        fontSize *= rect.width / measured.width
        attrs = attributes(fontSize)
        measured = (text as NSString).size(withAttributes: attrs)
      }
      (text as NSString).draw(
        at: NSPoint(
          x: rect.midX - measured.width / 2,
          y: rect.midY - measured.height / 2), withAttributes: attrs)
    case .svg(let svg): svg.draw(in: fitted, context: context)
    case .nativeSVG(let image, _):
      image.draw(in: fitted, from: .zero, operation: .sourceOver, fraction: 1)
    }
  }
}

/// A deliberately passive SVG subset: geometry, group transforms and presentation styles.
/// There is no browser, URL loader, script, CSS evaluator, image embedding or entity expansion.
/// Unsupported rendering features fail closed so the caller can display its normal fallback.
private final class IconSVG: NSObject, XMLParserDelegate {
  private enum Paint {
    case none, current
    case color(CGColor)
    func color(_ current: CGColor) -> CGColor? {
      switch self {
      case .none: return nil
      case .current: return current
      case .color(let value): return value
      }
    }
  }
  private struct Style {
    var fill: Paint = .current
    var stroke: Paint = .none
    var current = CGColor(gray: 0, alpha: 1)
    var width: CGFloat = 1
    var opacity: CGFloat = 1
    var fillOpacity: CGFloat = 1
    var strokeOpacity: CGFloat = 1
    var evenOdd = false
    var cap = CGLineCap.butt
    var join = CGLineJoin.miter
    var hidden = false
  }
  private struct Frame {
    var transform = CGAffineTransform.identity
    var style = Style()
    var ignore = false
  }
  private struct Shape {
    let path: CGPath
    let frame: Frame
  }
  private var stack: [Frame] = []
  private var shapes: [Shape] = []
  private var valid = true
  private var elements = 0
  private(set) var bounds = CGRect(x: 0, y: 0, width: 24, height: 24)

  convenience init?(_ data: Data) {
    self.init()
    guard data.count <= 512 * 1024, let text = String(data: data, encoding: .utf8),
      !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
      !text.localizedCaseInsensitiveContains("<!ENTITY")
    else { return nil }
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    parser.externalEntityResolvingPolicy = .never
    parser.delegate = self
    guard parser.parse(), valid, stack.isEmpty, !shapes.isEmpty else { return nil }
  }

  func draw(in rect: CGRect, context: CGContext) {
    context.saveGState()
    defer { context.restoreGState() }
    context.clip(to: rect)
    context.translateBy(x: rect.minX, y: rect.maxY)
    context.scaleBy(x: rect.width / bounds.width, y: -rect.height / bounds.height)
    context.translateBy(x: -bounds.minX, y: -bounds.minY)
    for shape in shapes where !shape.frame.style.hidden {
      let style = shape.frame.style
      context.saveGState()
      context.concatenate(shape.frame.transform)
      if let color = style.fill.color(style.current) {
        context.setAlpha(style.opacity * style.fillOpacity)
        context.setFillColor(color)
        context.addPath(shape.path)
        context.drawPath(using: style.evenOdd ? .eoFill : .fill)
      }
      if let color = style.stroke.color(style.current), style.width > 0 {
        context.setAlpha(style.opacity * style.strokeOpacity)
        context.setStrokeColor(color)
        context.setLineWidth(style.width)
        context.setLineCap(style.cap)
        context.setLineJoin(style.join)
        context.addPath(shape.path)
        context.strokePath()
      }
      context.restoreGState()
    }
  }

  func parser(
    _ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes raw: [String: String]
  ) {
    elements += 1
    guard elements <= 1024, stack.count < 32, !element.contains(":"),
      !raw.keys.contains(where: { $0.hasPrefix("on") || $0 == "href" || $0 == "xlink:href" })
    else {
      fail(parser)
      return
    }
    var frame = stack.last ?? Frame()
    if stack.isEmpty {
      guard element == "svg", raw["xmlns"] == nil || raw["xmlns"] == "http://www.w3.org/2000/svg"
      else {
        fail(parser)
        return
      }
      if let box = raw["viewBox"] {
        guard let values = IconNumbers.list(box), values.count == 4, values[2] >= 0.000001,
          values[3] >= 0.000001
        else {
          fail(parser)
          return
        }
        bounds = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
      } else {
        guard let width = length(raw["width"]), let height = length(raw["height"]),
          width >= 0.000001,
          height >= 0.000001
        else {
          fail(parser)
          return
        }
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
      }
    }
    if element == "title" || element == "desc" || frame.ignore {
      frame.ignore = true
      stack.append(frame)
      return
    }
    let unsupported: Set<String> = [
      "clip-path", "mask", "filter", "marker-start", "marker-mid",
      "marker-end", "stroke-dasharray", "stroke-dashoffset", "vector-effect", "paint-order",
    ]
    guard
      ["svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon"].contains(
        element),
      unsupported.isDisjoint(with: raw.keys)
    else {
      fail(parser)
      return
    }
    var attributes = raw
    if let inline = raw["style"] {
      for declaration in inline.split(separator: ";") {
        let pair = declaration.split(separator: ":", maxSplits: 1)
        guard pair.count == 2 else {
          fail(parser)
          return
        }
        let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !unsupported.contains(key) else {
          fail(parser)
          return
        }
        attributes[key] = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    guard apply(attributes, style: &frame.style) else {
      fail(parser)
      return
    }
    if let source = raw["transform"] {
      guard let transform = IconNumbers.transform(source) else {
        fail(parser)
        return
      }
      frame.transform = transform.concatenating(frame.transform)
      guard
        [
          frame.transform.a, frame.transform.b, frame.transform.c, frame.transform.d,
          frame.transform.tx, frame.transform.ty,
        ].allSatisfy({ $0.isFinite && abs($0) <= 1e9 })
      else {
        fail(parser)
        return
      }
    }
    stack.append(frame)
    guard element != "svg", element != "g" else { return }
    guard let path = geometry(element, raw) else {
      fail(parser)
      return
    }
    shapes.append(Shape(path: path, frame: frame))
  }

  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    if !stack.isEmpty { stack.removeLast() }
  }
  func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?)
    -> Data?
  {
    fail(parser)
    return nil
  }
  private func fail(_ parser: XMLParser) {
    valid = false
    parser.abortParsing()
  }

  private func length(_ text: String?, fallback: CGFloat? = nil) -> CGFloat? {
    guard let text else { return fallback }
    let clean = text.hasSuffix("px") ? String(text.dropLast(2)) : text
    guard let value = Double(clean), value.isFinite, abs(value) <= 1e7 else { return nil }
    return CGFloat(value)
  }

  private func geometry(_ name: String, _ attributes: [String: String]) -> CGPath? {
    if name == "path" { return attributes["d"].flatMap { IconPath.parse($0) } }
    if name == "polygon" || name == "polyline" {
      guard let source = attributes["points"], let points = IconNumbers.list(source),
        points.count >= 4, points.count % 2 == 0
      else { return nil }
      let path = CGMutablePath()
      path.move(to: CGPoint(x: points[0], y: points[1]))
      for index in stride(from: 2, to: points.count, by: 2) {
        path.addLine(to: CGPoint(x: points[index], y: points[index + 1]))
      }
      if name == "polygon" { path.closeSubpath() }
      return path
    }
    if name == "line" {
      guard let x1 = length(attributes["x1"], fallback: 0),
        let y1 = length(attributes["y1"], fallback: 0),
        let x2 = length(attributes["x2"], fallback: 0),
        let y2 = length(attributes["y2"], fallback: 0)
      else { return nil }
      let path = CGMutablePath()
      path.move(to: CGPoint(x: x1, y: y1))
      path.addLine(to: CGPoint(x: x2, y: y2))
      return path
    }
    if name == "rect" {
      guard let x = length(attributes["x"], fallback: 0),
        let y = length(attributes["y"], fallback: 0),
        let width = length(attributes["width"]), let height = length(attributes["height"]),
        width >= 0, height >= 0,
        let rx = length(attributes["rx"], fallback: length(attributes["ry"], fallback: 0)),
        let ry = length(attributes["ry"], fallback: rx), rx >= 0, ry >= 0
      else { return nil }
      return CGPath(
        roundedRect: CGRect(x: x, y: y, width: width, height: height),
        cornerWidth: min(rx, width / 2), cornerHeight: min(ry, height / 2), transform: nil)
    }
    guard let x = length(attributes["cx"], fallback: 0),
      let y = length(attributes["cy"], fallback: 0),
      let rx = length(attributes[name == "circle" ? "r" : "rx"]),
      let ry = name == "circle" ? rx : length(attributes["ry"]), rx >= 0, ry >= 0
    else { return nil }
    return CGPath(
      ellipseIn: CGRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2), transform: nil)
  }

  private func apply(_ attributes: [String: String], style: inout Style) -> Bool {
    if let value = attributes["color"], value != "inherit" {
      guard case .color(let color)? = paint(value) else { return false }
      style.current = color
    }
    for (key, assign) in [("fill", true), ("stroke", false)] {
      if let value = attributes[key], value != "inherit" {
        guard let paint = paint(value) else { return false }
        if assign { style.fill = paint } else { style.stroke = paint }
      }
    }
    for key in ["opacity", "fill-opacity", "stroke-opacity", "stroke-width"] {
      if let source = attributes[key], source != "inherit" {
        guard let value = length(source), value >= 0 else { return false }
        switch key {
        case "opacity": style.opacity *= min(1, value)
        case "fill-opacity": style.fillOpacity = min(1, value)
        case "stroke-opacity": style.strokeOpacity = min(1, value)
        default: style.width = value
        }
      }
    }
    if let rule = attributes["fill-rule"] {
      guard ["evenodd", "nonzero", "inherit"].contains(rule) else { return false }
      if rule != "inherit" { style.evenOdd = rule == "evenodd" }
    }
    if let value = attributes["stroke-linecap"] {
      guard let cap: CGLineCap = ["butt": .butt, "round": .round, "square": .square][value] else {
        return false
      }
      style.cap = cap
    }
    if let value = attributes["stroke-linejoin"] {
      guard let join: CGLineJoin = ["miter": .miter, "round": .round, "bevel": .bevel][value] else {
        return false
      }
      style.join = join
    }
    style.hidden =
      style.hidden || attributes["display"] == "none" || attributes["visibility"] == "hidden"
    return true
  }

  private func paint(_ value: String) -> Paint? {
    let source = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if source == "none" { return Paint.none }
    if source == "currentcolor" { return .current }
    let names: [String: String] = [
      "black": "000000", "white": "ffffff", "red": "ff0000",
      "green": "008000", "blue": "0000ff", "gray": "808080", "grey": "808080",
      "yellow": "ffff00", "orange": "ffa500", "purple": "800080", "pink": "ffc0cb",
      "cyan": "00ffff", "magenta": "ff00ff", "transparent": "00000000",
    ]
    if source.hasPrefix("#") || names[source] != nil {
      var hex = source.hasPrefix("#") ? String(source.dropFirst()) : names[source]!
      if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
      guard hex.count == 6 || hex.count == 8, let bits = UInt32(hex, radix: 16) else { return nil }
      let alpha = hex.count == 8 ? CGFloat(bits & 255) / 255 : 1
      let rgb = hex.count == 8 ? bits >> 8 : bits
      return .color(
        CGColor(
          srgbRed: CGFloat(rgb >> 16) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
          blue: CGFloat(rgb & 255) / 255, alpha: alpha))
    }
    if source.hasPrefix("rgb(") || source.hasPrefix("rgba("), source.hasSuffix(")"),
      let opening = source.firstIndex(of: "(")
    {
      let parts = source[source.index(after: opening)..<source.index(before: source.endIndex)]
        .split(separator: ",")
      guard parts.count == (source.hasPrefix("rgba") ? 4 : 3) else { return nil }
      var values: [CGFloat] = []
      for (index, part) in parts.enumerated() {
        let text = part.trimmingCharacters(in: .whitespacesAndNewlines)
        let percent = text.hasSuffix("%")
        guard let value = Double(percent ? String(text.dropLast()) : text), value.isFinite else {
          return nil
        }
        values.append(min(1, max(0, CGFloat(value) / (percent ? 100 : index == 3 ? 1 : 255))))
      }
      return .color(
        CGColor(
          srgbRed: values[0], green: values[1], blue: values[2],
          alpha: values.count == 4 ? values[3] : 1))
    }
    return nil
  }
}

private struct IconNumbers {
  var bytes: [UInt8]
  var position = 0
  init(_ source: String) { bytes = Array(source.utf8) }
  mutating func space() {
    while position < bytes.count && [9, 10, 13, 32, 44].contains(bytes[position]) { position += 1 }
  }
  mutating func number() -> CGFloat? {
    space()
    let start = position
    if position < bytes.count && (bytes[position] == 43 || bytes[position] == 45) { position += 1 }
    var digits = 0
    while position < bytes.count && (48...57).contains(bytes[position]) {
      digits += 1
      position += 1
    }
    if position < bytes.count && bytes[position] == 46 {
      position += 1
      while position < bytes.count && (48...57).contains(bytes[position]) {
        digits += 1
        position += 1
      }
    }
    guard digits > 0 else {
      position = start
      return nil
    }
    if position < bytes.count && (bytes[position] == 69 || bytes[position] == 101) {
      position += 1
      if position < bytes.count && (bytes[position] == 43 || bytes[position] == 45) {
        position += 1
      }
      let exponent = position
      while position < bytes.count && (48...57).contains(bytes[position]) { position += 1 }
      guard position > exponent else {
        position = start
        return nil
      }
    }
    guard let value = Double(String(decoding: bytes[start..<position], as: UTF8.self)),
      value.isFinite, abs(value) <= 1e7
    else { return nil }
    return CGFloat(value)
  }
  mutating func flag() -> CGFloat? {
    space()
    guard position < bytes.count, bytes[position] == 48 || bytes[position] == 49 else { return nil }
    let value = CGFloat(bytes[position] - 48)
    position += 1
    return value
  }
  static func list(_ source: String) -> [CGFloat]? {
    var scanner = IconNumbers(source)
    var values: [CGFloat] = []
    scanner.space()
    while scanner.position < scanner.bytes.count {
      guard values.count < 16_384, let value = scanner.number() else { return nil }
      values.append(value)
      scanner.space()
    }
    return values
  }
  static func transform(_ source: String) -> CGAffineTransform? {
    var scanner = IconNumbers(source)
    var result = CGAffineTransform.identity
    var count = 0
    scanner.space()
    while scanner.position < scanner.bytes.count {
      count += 1
      guard count <= 32 else { return nil }
      let start = scanner.position
      while scanner.position < scanner.bytes.count
        && ((65...90).contains(scanner.bytes[scanner.position])
          || (97...122).contains(scanner.bytes[scanner.position]))
      { scanner.position += 1 }
      let name = String(decoding: scanner.bytes[start..<scanner.position], as: UTF8.self)
      scanner.space()
      guard scanner.position < scanner.bytes.count, scanner.bytes[scanner.position] == 40 else {
        return nil
      }
      scanner.position += 1
      var values: [CGFloat] = []
      scanner.space()
      while scanner.position < scanner.bytes.count && scanner.bytes[scanner.position] != 41 {
        guard values.count < 6, let value = scanner.number() else { return nil }
        values.append(value)
        scanner.space()
      }
      guard scanner.position < scanner.bytes.count else { return nil }
      scanner.position += 1
      let next: CGAffineTransform
      switch (name, values.count) {
      case ("matrix", 6):
        next = CGAffineTransform(
          a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
      case ("translate", 1), ("translate", 2):
        next = CGAffineTransform(translationX: values[0], y: values.count == 2 ? values[1] : 0)
      case ("scale", 1), ("scale", 2):
        next = CGAffineTransform(scaleX: values[0], y: values.count == 2 ? values[1] : values[0])
      case ("rotate", 1): next = CGAffineTransform(rotationAngle: values[0] * .pi / 180)
      case ("rotate", 3):
        let cosine = cos(values[0] * .pi / 180)
        let sine = sin(values[0] * .pi / 180)
        next = CGAffineTransform(
          a: cosine, b: sine, c: -sine, d: cosine,
          tx: values[1] - cosine * values[1] + sine * values[2],
          ty: values[2] - sine * values[1] - cosine * values[2])
      case ("skewX", 1):
        next = CGAffineTransform(a: 1, b: 0, c: tan(values[0] * .pi / 180), d: 1, tx: 0, ty: 0)
      case ("skewY", 1):
        next = CGAffineTransform(a: 1, b: tan(values[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
      default: return nil
      }
      result = next.concatenating(result)
      guard
        [result.a, result.b, result.c, result.d, result.tx, result.ty].allSatisfy({
          $0.isFinite && abs($0) <= 1e9
        })
      else { return nil }
      scanner.space()
    }
    return result
  }
}

private enum IconPath {
  static func parse(_ source: String) -> CGPath? {
    var scanner = IconNumbers(source)
    let path = CGMutablePath()
    var command: UInt8 = 0
    var previous: UInt8 = 0
    var current = CGPoint.zero
    var start = CGPoint.zero
    var control = CGPoint.zero
    var segments = 0
    scanner.space()
    while scanner.position < scanner.bytes.count {
      let byte = scanner.bytes[scanner.position]
      if (65...90).contains(byte) || (97...122).contains(byte) {
        command = byte
        scanner.position += 1
      }
      let upper = command >= 97 ? command - 32 : command
      let relative = command >= 97
      if upper == 90 {
        guard segments > 0 else { return nil }
        path.closeSubpath()
        current = start
        control = current
        previous = upper
        command = 0
        scanner.space()
        continue
      }
      let counts: [UInt8: Int] = [77: 2, 76: 2, 72: 1, 86: 1, 67: 6, 83: 4, 81: 4, 84: 2, 65: 7]
      guard let count = counts[upper], segments > 0 || upper == 77, segments < 8192 else {
        return nil
      }
      var values: [CGFloat] = []
      for index in 0..<count {
        guard
          let value = upper == 65 && (index == 3 || index == 4) ? scanner.flag() : scanner.number()
        else { return nil }
        values.append(value)
      }
      func point(_ index: Int) -> CGPoint {
        CGPoint(
          x: values[index] + (relative ? current.x : 0),
          y: values[index + 1] + (relative ? current.y : 0))
      }
      var nextControl: CGPoint?
      switch upper {
      case 77:
        current = point(0)
        start = current
        path.move(to: current)
        command = relative ? 108 : 76
      case 76:
        current = point(0)
        path.addLine(to: current)
      case 72:
        current.x = values[0] + (relative ? current.x : 0)
        path.addLine(to: current)
      case 86:
        current.y = values[0] + (relative ? current.y : 0)
        path.addLine(to: current)
      case 67:
        let c1 = point(0)
        let c2 = point(2)
        let end = point(4)
        path.addCurve(to: end, control1: c1, control2: c2)
        current = end
        nextControl = c2
      case 83:
        let c1 =
          [67, 83].contains(previous)
          ? CGPoint(x: current.x * 2 - control.x, y: current.y * 2 - control.y) : current
        let c2 = point(0)
        let end = point(2)
        path.addCurve(to: end, control1: c1, control2: c2)
        current = end
        nextControl = c2
      case 81:
        let c1 = point(0)
        let end = point(2)
        path.addQuadCurve(to: end, control: c1)
        current = end
        nextControl = c1
      case 84:
        let c1 =
          [81, 84].contains(previous)
          ? CGPoint(x: current.x * 2 - control.x, y: current.y * 2 - control.y) : current
        let end = point(0)
        path.addQuadCurve(to: end, control: c1)
        current = end
        nextControl = c1
      case 65:
        guard [0, 1].contains(values[3]), [0, 1].contains(values[4]) else { return nil }
        let end = point(5)
        guard
          arc(
            path, from: current, to: end, rx: abs(values[0]), ry: abs(values[1]),
            angle: values[2], large: values[3] == 1, sweep: values[4] == 1)
        else { return nil }
        current = end
      default: return nil
      }
      control = nextControl ?? current
      previous = upper
      segments += 1
      guard
        [current.x, current.y, control.x, control.y].allSatisfy({ $0.isFinite && abs($0) <= 1e9 })
      else { return nil }
      scanner.space()
    }
    return segments > 0 ? path : nil
  }

  private static func arc(
    _ path: CGMutablePath, from a: CGPoint, to b: CGPoint, rx: CGFloat,
    ry: CGFloat, angle: CGFloat, large: Bool, sweep: Bool
  ) -> Bool {
    guard a != b else { return true }
    guard rx >= 0.000001, ry >= 0.000001 else {
      path.addLine(to: b)
      return true
    }
    let phi = angle.truncatingRemainder(dividingBy: 360) * .pi / 180
    let cosine = cos(phi)
    let sine = sin(phi)
    let dx = (a.x - b.x) / 2
    let dy = (a.y - b.y) / 2
    let x = cosine * dx + sine * dy
    let y = -sine * dx + cosine * dy
    let factor = max(1, sqrt(x * x / (rx * rx) + y * y / (ry * ry)))
    let rx = rx * factor
    let ry = ry * factor
    let denominator = rx * rx * y * y + ry * ry * x * x
    let coefficient =
      (large == sweep ? -1.0 : 1.0)
      * sqrt(
        max(
          0,
          (rx * rx * ry * ry - denominator) / max(denominator, CGFloat.leastNonzeroMagnitude)))
    let cx = coefficient * rx * y / ry
    let cy = -coefficient * ry * x / rx
    let center = CGPoint(
      x: cosine * cx - sine * cy + (a.x + b.x) / 2,
      y: sine * cx + cosine * cy + (a.y + b.y) / 2)
    let first = atan2((y - cy) / ry, (x - cx) / rx)
    var delta = atan2((-y - cy) / ry, (-x - cx) / rx) - first
    guard [center.x, center.y, first, delta, rx, ry].allSatisfy(\.isFinite) else { return false }
    if sweep && delta < 0 { delta += 2 * .pi }
    if !sweep && delta > 0 { delta -= 2 * .pi }
    let count = max(1, Int(ceil(abs(delta) / (.pi / 2))))
    func location(_ theta: CGFloat) -> CGPoint {
      CGPoint(
        x: center.x + rx * cosine * cos(theta) - ry * sine * sin(theta),
        y: center.y + rx * sine * cos(theta) + ry * cosine * sin(theta))
    }
    func tangent(_ theta: CGFloat) -> CGPoint {
      CGPoint(
        x: -rx * cosine * sin(theta) - ry * sine * cos(theta),
        y: -rx * sine * sin(theta) + ry * cosine * cos(theta))
    }
    for index in 0..<count {
      let begin = first + delta * CGFloat(index) / CGFloat(count)
      let end = first + delta * CGFloat(index + 1) / CGFloat(count)
      let alpha = 4 / 3 * tan((end - begin) / 4)
      let p = location(begin)
      let q = index == count - 1 ? b : location(end)
      let u = tangent(begin)
      let v = tangent(end)
      let control1 = CGPoint(x: p.x + alpha * u.x, y: p.y + alpha * u.y)
      let control2 = CGPoint(x: q.x - alpha * v.x, y: q.y - alpha * v.y)
      guard
        [control1.x, control1.y, control2.x, control2.y, q.x, q.y]
          .allSatisfy({ $0.isFinite && abs($0) <= 1e12 })
      else { return false }
      path.addCurve(to: q, control1: control1, control2: control2)
    }
    return true
  }
}
