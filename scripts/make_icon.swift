// Renders the 1024×1024 app icon: usage `swift make_icon.swift out.png`
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpaceCreateDeviceRGB()

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// macOS icon grid: 824pt rounded square centered in 1024.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x000000, 0.35))
ctx.addPath(shape)
ctx.setFillColor(rgb(0x1A1440))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()

// Night-sky base.
let base = CGGradient(colorsSpace: space, colors: [rgb(0x2A1F6E), rgb(0x16123A), rgb(0x0B1A3A)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(base, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])

// Aurora glows.
func glow(_ center: CGPoint, _ radius: CGFloat, _ color: UInt32, _ alpha: CGFloat) {
    let g = CGGradient(colorsSpace: space, colors: [rgb(color, alpha), rgb(color, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}
glow(CGPoint(x: 300, y: 820), 520, 0x7B5CFF, 0.75)
glow(CGPoint(x: 800, y: 260), 520, 0x1FC8D8, 0.6)
glow(CGPoint(x: 760, y: 820), 300, 0xF07AAA, 0.28)

// Waveform bars with a violet→cyan gradient.
let heights: [CGFloat] = [0.20, 0.38, 0.62, 0.86, 1.0, 0.78, 0.54, 0.34, 0.18]
let barWidth: CGFloat = 46
let gap: CGFloat = 26
let maxHeight: CGFloat = 470
let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
var x = (size - totalWidth) / 2
let barsPath = CGMutablePath()
for h in heights {
    let height = max(maxHeight * h, barWidth)
    barsPath.addPath(CGPath(roundedRect: CGRect(x: x, y: size / 2 - height / 2, width: barWidth, height: height),
                            cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    x += barWidth + gap
}

ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 40, color: rgb(0xA8C8FF, 0.65))
ctx.addPath(barsPath)
ctx.setFillColor(rgb(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(barsPath)
ctx.clip()
let bars = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF), rgb(0xE4E0FF), rgb(0xC9F4FA)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(bars, start: CGPoint(x: 250, y: 760), end: CGPoint(x: 780, y: 260), options: [])
ctx.restoreGState()

// Glass highlight on the upper half.
let shine = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(shine, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
ctx.restoreGState()

// Hairline rim.
ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.setStrokeColor(rgb(0xFFFFFF, 0.14))
ctx.setLineWidth(3)
ctx.strokePath()

NSGraphicsContext.current = nil
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
