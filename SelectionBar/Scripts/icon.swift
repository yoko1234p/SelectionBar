import AppKit

let path = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let pixels = size * scale
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    let inset = Double(pixels) * 0.06
    let background = NSBezierPath(
      roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: Double(pixels) * 0.22,
      yRadius: Double(pixels) * 0.22)
    NSColor(calibratedRed: 0.96, green: 0.34, blue: 0.18, alpha: 1).setFill()
    background.fill()
    let selection = NSRect(
      x: Double(pixels) * 0.2, y: Double(pixels) * 0.3, width: Double(pixels) * 0.6,
      height: Double(pixels) * 0.4)
    NSColor.white.withAlphaComponent(0.23).setFill()
    NSBezierPath(
      roundedRect: selection, xRadius: Double(pixels) * 0.05, yRadius: Double(pixels) * 0.05
    ).fill()
    let line = NSBezierPath()
    line.lineWidth = max(1, Double(pixels) * 0.055)
    line.lineCapStyle = .round
    let cx = Double(pixels) * 0.5
    let y1 = Double(pixels) * 0.24
    let y2 = Double(pixels) * 0.76
    let cap = Double(pixels) * 0.13
    line.move(to: NSPoint(x: cx, y: y1))
    line.line(to: NSPoint(x: cx, y: y2))
    line.move(to: NSPoint(x: cx - cap, y: y1))
    line.line(to: NSPoint(x: cx + cap, y: y1))
    line.move(to: NSPoint(x: cx - cap, y: y2))
    line.line(to: NSPoint(x: cx + cap, y: y2))
    NSColor.white.setStroke()
    line.stroke()
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let data = bitmap.representation(using: .png, properties: [:])!
    let suffix = scale == 2 ? "@2x" : ""
    try data.write(
      to: URL(fileURLWithPath: path).appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
  }
}
