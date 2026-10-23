import AppKit
import SelectionBarCore
import XCTest

@testable import SelectionBar

final class IconTests: XCTestCase {
  private func svg(_ content: String, attributes: String = "") -> Data {
    Data(
      "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' \(attributes)>\(content)</svg>"
        .utf8)
  }

  @MainActor private func pixel(_ image: NSImage, _ x: Int, _ y: Int) throws -> NSColor {
    let representation = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 48,
        pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: representation))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: 48, height: 48))
    NSGraphicsContext.restoreGraphicsState()
    return try XCTUnwrap(representation.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
  }

  @MainActor func testNativeGradientAndClipHaveActualPixels() throws {
    let document = try XCTUnwrap(
      SafeIconSVG.document(
        svg(
          """
          <defs><linearGradient id='a'><stop stop-color='#f00'/><stop offset='1' stop-color='#00f'/></linearGradient>
          <clipPath id='b'><circle cx='12' cy='12' r='9'/></clipPath></defs>
          <rect width='24' height='24' fill='url(#a)' clip-path='url(#b)'/>
          """, attributes: "height='1em'")))
    let image = try XCTUnwrap(SafeIconSVG.image(document))
    XCTAssertEqual(image.size, NSSize(width: 24, height: 24))
    let left = try pixel(image, 12, 24)
    let right = try pixel(image, 36, 24)
    XCTAssertGreaterThan(left.redComponent, right.redComponent + 0.2)
    XCTAssertGreaterThan(right.blueComponent, left.blueComponent + 0.2)
    XCTAssertEqual(try pixel(image, 0, 0).alphaComponent, 0, accuracy: 0.01)
    XCTAssertTrue(document.hasColor)
  }

  @MainActor func testMasksAndLocalUseRenderWithoutExternalResources() throws {
    let document = try XCTUnwrap(
      SafeIconSVG.document(
        svg(
          """
          <defs><rect id='square' width='24' height='24'/><mask id='m' mask-type='alpha'>
          <circle cx='12' cy='12' r='7' fill='white'/></mask></defs>
          <use href='#square' fill='red' mask='url(#m)'/>
          """)))
    let image = try XCTUnwrap(SafeIconSVG.image(document))
    XCTAssertGreaterThan(try pixel(image, 24, 24).alphaComponent, 0.9)
    XCTAssertLessThan(try pixel(image, 0, 0).alphaComponent, 0.01)
    let monochrome = try XCTUnwrap(
      SafeIconSVG.document(
        svg(
          """
          <defs><mask id='m' mask-type='luminance'><circle cx='12' cy='12' r='7' fill='white'/></mask></defs>
          <rect width='24' height='24' fill='currentColor' mask='url(#m)'/>
          """)))
    XCTAssertFalse(
      monochrome.hasColor, "A white mask must not force a monochrome icon into color mode")
  }

  @MainActor func testInlineRasterAndFilterHaveActualPixels() throws {
    let bitmap = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    for x in 0..<2 {
      for y in 0..<2 {
        bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y)
      }
    }
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let document = try XCTUnwrap(
      SafeIconSVG.document(
        svg(
          "<image width='24' height='24' href='data:image/png;base64,\(png.base64EncodedString())'/>"
        )))
    XCTAssertTrue(document.hasColor)
    let raster = try XCTUnwrap(SafeIconSVG.image(document))
    let center = try pixel(raster, 24, 24)
    XCTAssertGreaterThan(center.redComponent, 0.8)
    XCTAssertGreaterThan(center.alphaComponent, 0.9)
    let filtered = try XCTUnwrap(
      SafeIconSVG.document(
        svg(
          """
          <defs><filter id='f' x='-50%' y='-50%' width='200%' height='200%'>
          <feGaussianBlur stdDeviation='1'/></filter></defs>
          <rect x='6' y='6' width='12' height='12' filter='url(#f)'/>
          """)))
    let image = try XCTUnwrap(SafeIconSVG.image(filtered))
    XCTAssertGreaterThan(try pixel(image, 24, 24).alphaComponent, 0.9)
    let edge = try pixel(image, 11, 24).alphaComponent
    XCTAssertGreaterThan(edge, 0.05)
    XCTAssertLessThan(edge, 0.95)
  }

  func testRejectsActiveExternalAndUnboundedSVG() {
    let invalid = [
      "<script>alert(1)</script>", "<foreignObject/>", "<image href='file:///etc/passwd'/>",
      "<image href='https://example.com/a.png'/>", "<use href='other.svg#a'/>",
      "<style>rect{fill:red}</style>", "<rect width='2' height='2' onclick='x'/>",
      "<rect fill='url(https://example.com)'/>", "<rect style='fill:var(--x)'/>",
      "<rect style='fill:u\\72l(https://example.com)'/>",
      "<defs><g id='a'><use href='#a'/></g></defs><use href='#a'/>",
      "<defs><g id='a'><use href='#b'/></g><g id='b'><use href='#a'/></g></defs>",
      "<rect clip-path='url(#missing)'/>",
      "<filter id='f'><feGaussianBlur stdDeviation='999999'/></filter>",
    ]
    for content in invalid { XCTAssertNil(SafeIconSVG.document(svg(content)), content) }
    XCTAssertNil(
      SafeIconSVG.document(
        Data("<!DOCTYPE svg [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><svg>&x;</svg>".utf8)))
    XCTAssertNil(
      SafeIconSVG.document(
        svg(String(repeating: "<g>", count: 40) + String(repeating: "</g>", count: 40))))
    XCTAssertNil(SafeIconSVG.document(Data("<svg viewBox='0 0 1e999 24'><path/></svg>".utf8)))
    var bomb = "<defs><path id='a0' d='M0 0h1v1z'/>"
    for i in 1...16 { bomb += "<g id='a\(i)'><use href='#a\(i-1)'/><use href='#a\(i-1)'/></g>" }
    XCTAssertNil(SafeIconSVG.document(svg(bomb + "</defs><use href='#a16'/>")))
    var deep = "<defs><path id='a0' d='M0 0h1v1z'/>"
    for i in 1...70 { deep += "<g id='a\(i)'><use href='#a\(i-1)'/></g>" }
    XCTAssertNil(SafeIconSVG.document(svg(deep + "</defs><use href='#a70'/>")))
    let complexPath = "M0 0" + String(repeating: "l1 0", count: 1000) + "z"
    let repeatedPath =
      "<defs><path id='p' d='\(complexPath)'/></defs>"
      + String(repeating: "<use href='#p'/>", count: 64)
    XCTAssertNil(SafeIconSVG.document(svg(repeatedPath)))
  }

  @MainActor func testExistingGeometryAndPropertyModifiers() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
    let content = String(decoding: svg("<path d='M2 2h20v20H2Z' fill='red'/>"), as: UTF8.self)
    let plain = try XCTUnwrap(
      ExtensionIcon.image(config: .string("svg:" + content), packageRoot: root))
    XCTAssertTrue(plain.isTemplate)
    let color = try XCTUnwrap(
      ExtensionIcon.image(
        config: .string("svg:" + content), packageRoot: root,
        properties: ["preserveColor": .bool(true)]))
    XCTAssertFalse(color.isTemplate)
    let normalized = try XCTUnwrap(
      ExtensionIcon.image(
        config: .string("preserve-color svg:" + content), packageRoot: root,
        properties: ["preservecolor": .bool(false), "scale": .number(50)]))
    XCTAssertTrue(normalized.isTemplate)
    XCTAssertNotNil(ExtensionIcon.image(config: .string("circle filled text:A"), packageRoot: root))
    XCTAssertNotNil(ExtensionIcon.image(config: .string("symbol:doc.on.doc"), packageRoot: root))
    XCTAssertNil(
      ExtensionIcon.image(
        config: .string("text:A"), packageRoot: root, properties: ["scale": .number(.infinity)]))
  }

  func testIconifyIdentifierCannotBecomeArbitraryURL() throws {
    let icon = try XCTUnwrap(IconifyIdentifier("iconify:mdi:content-copy"))
    XCTAssertEqual(icon.url.absoluteString, "https://api.iconify.design/mdi/content-copy.svg")
    for value in [
      "iconify:../x:a", "iconify:mdi:../../foo", "iconify:mdi:x?text=private",
      "iconify:https://example:x", "iconify:mdi:", "iconify:mdi:x#y",
    ] {
      XCTAssertNil(IconifyIdentifier(value))
    }
  }

  @MainActor func testIconifyDedupAndAsynchronousRefresh() async throws {
    actor Counter {
      var value = 0
      func fetch() async -> Data {
        value += 1
        try? await Task.sleep(nanoseconds: 40_000_000)
        return Data("<svg viewBox='0 0 24 24'><path d='M0 0h24v24z'/></svg>".utf8)
      }
    }
    let counter = Counter()
    let store = IconifyAssets(directory: nil, loader: { _ in await counter.fetch() })
    let identifier = try XCTUnwrap(IconifyIdentifier("iconify:mdi:content-copy"))
    for _ in 0..<30 { XCTAssertNil(store.document(for: identifier)) }
    for _ in 0..<100 {
      try await Task.sleep(nanoseconds: 10_000_000)
      if store.document(for: identifier) != nil { break }
    }
    XCTAssertNotNil(store.document(for: identifier))
    let calls = await counter.value
    XCTAssertEqual(calls, 1)
  }

  @MainActor func testIconifyDiskCacheSurvivesOffline() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let identifier = try XCTUnwrap(IconifyIdentifier("iconify:mdi:content-copy"))
    let source = svg("<path d='M0 0h24v24z'/>")
    let online = IconifyAssets(directory: directory, loader: { _ in source })
    XCTAssertNil(online.document(for: identifier))
    for _ in 0..<100 {
      try await Task.sleep(nanoseconds: 10_000_000)
      if online.document(for: identifier) != nil { break }
    }
    XCTAssertNotNil(online.document(for: identifier))
    let cachedFile = directory.appendingPathComponent(identifier.filename)
    let diskData = try Data(contentsOf: cachedFile)
    XCTAssertNotNil(SafeIconSVG.document(diskData))
    let offline = IconifyAssets(
      directory: directory,
      loader: { _ in
        XCTFail("offline cache requested network")
        throw URLError(.notConnectedToInternet)
      })
    XCTAssertNil(offline.document(for: identifier))
    for _ in 0..<100 {
      try await Task.sleep(nanoseconds: 10_000_000)
      if offline.document(for: identifier) != nil { break }
    }
    XCTAssertNotNil(offline.document(for: identifier))
    let permissions =
      try FileManager.default.attributesOfItem(
        atPath: directory.appendingPathComponent(identifier.filename).path)[.posixPermissions]
      as? Int
    XCTAssertEqual(permissions, 0o600)
  }

  @MainActor func testIconifyCancellationReachesTransport() async throws {
    actor State {
      var began = false
      var cancelled = false
      func fetch() async throws -> Data {
        began = true
        do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch {
          cancelled = true
          throw error
        }
        return Data()
      }
    }
    let state = State()
    let store = IconifyAssets(directory: nil, loader: { _ in try await state.fetch() })
    _ = store.document(for: try XCTUnwrap(IconifyIdentifier("iconify:mdi:copy")))
    for _ in 0..<100 {
      if await state.began { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    store.cancel()
    for _ in 0..<100 {
      if await state.cancelled { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let cancelled = await state.cancelled
    XCTAssertTrue(cancelled)
  }
}
