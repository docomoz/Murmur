// Frames a raw capture of the Murmur panel into a 2880×1800 Mac App Store screenshot.
//
//   swift scripts/make_screenshot.swift <panel.png> "<Title>" "<Subtitle>" <out.png>
//
// Capture the panel with ⌘⇧4, then Space, then click the panel: macOS saves it with a
// transparent background and a soft shadow, which is exactly what this script expects.
import AppKit

let args = CommandLine.arguments
guard args.count == 5, let panel = NSImage(contentsOfFile: args[1]) else {
    print("usage: swift make_screenshot.swift <panel.png> \"<Title>\" \"<Subtitle>\" <out.png>")
    exit(1)
}
let title = args[2], subtitle = args[3], output = args[4]
let icon = NSImage(contentsOfFile: "Resources/icon-1024.png")

let W: CGFloat = 2880, H: CGFloat = 1800
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpaceCreateDeviceRGB()

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func glow(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: UInt32, _ a: CGFloat) {
    let g = CGGradient(colorsSpace: space, colors: [rgb(color, a), rgb(color, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: CGPoint(x: x, y: y), startRadius: 0,
                           endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
}

// Night-sky backdrop in the colors of the app icon.
let base = CGGradient(colorsSpace: space, colors: [rgb(0x2A1F6E), rgb(0x16123A), rgb(0x0B1A3A)] as CFArray,
                      locations: [0, 0.55, 1])!
ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
glow(500, 1500, 1300, 0x7B5CFF, 0.55)
glow(2500, 300, 1300, 0x1FC8D8, 0.4)
glow(2300, 1650, 800, 0xF07AAA, 0.22)

// Text block on the left.
let left: CGFloat = 220
if let icon {
    icon.draw(in: NSRect(x: left - 30, y: 1180, width: 300, height: 300))
}
func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, y: CGFloat, width: CGFloat) {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = size * 0.12
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attributed = NSAttributedString(string: text, attributes: [
        .font: font, .foregroundColor: NSColor.white.withAlphaComponent(alpha), .paragraphStyle: style,
    ])
    let bounds = attributed.boundingRect(with: NSSize(width: width, height: 1000), options: [.usesLineFragmentOrigin])
    attributed.draw(with: NSRect(x: left, y: y - bounds.height, width: width, height: bounds.height),
                    options: [.usesLineFragmentOrigin])
}
draw(title, size: 118, weight: .bold, alpha: 1, y: 1130, width: 1300)
draw(subtitle, size: 54, weight: .regular, alpha: 0.78, y: 760, width: 1200)

// The panel on the right, as large as fits.
let maxH: CGFloat = 1640, maxW: CGFloat = 1180
let scale = min(maxH / panel.size.height, maxW / panel.size.width)
let size = NSSize(width: panel.size.width * scale, height: panel.size.height * scale)
let rect = NSRect(x: W - 260 - size.width + (maxW - size.width) / 2, y: (H - size.height) / 2,
                  width: size.width, height: size.height)
panel.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("✓ \(output)")
