import AppKit

let px = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
rep.size = NSSize(width: px, height: px)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let full = NSRect(x: 0, y: 0, width: px, height: px)

// Brand-green gradient, light top → deep bottom
let top = NSColor(calibratedRed: 0.26, green: 0.78, blue: 0.52, alpha: 1)
let bottom = NSColor(calibratedRed: 0.07, green: 0.52, blue: 0.31, alpha: 1)
NSGradient(colors: [top, bottom])!.draw(in: full, angle: -90)

// Soft radial glow behind the mark for depth
let glow = NSGradient(colors: [
    NSColor(calibratedWhite: 1, alpha: 0.22),
    NSColor(calibratedWhite: 1, alpha: 0),
])!
glow.draw(fromCenter: NSPoint(x: 470, y: 560), radius: 0,
          toCenter: NSPoint(x: 470, y: 560), radius: 520, options: [])

func drawSymbol(_ name: String, height: CGFloat, center: NSPoint, weight: NSFont.Weight, alpha: CGFloat = 1) {
    let cfg = NSImage.SymbolConfiguration(pointSize: 300, weight: weight)
        .applying(.init(paletteColors: [NSColor.white.withAlphaComponent(alpha)]))
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else {
        fatalError("missing symbol \(name)")
    }
    let natural = symbol.size
    let width = natural.width / natural.height * height
    let rect = NSRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
}

// Main mark, nudged left/down to leave air for the sparkle
drawSymbol("fork.knife", height: 560, center: NSPoint(x: 482, y: 488), weight: .medium)
// AI sparkle, echoing the Analyze button
drawSymbol("sparkles", height: 200, center: NSPoint(x: 768, y: 762), weight: .semibold)

NSGraphicsContext.restoreGraphicsState()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
