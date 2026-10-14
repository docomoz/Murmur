// Renders the DMG window background at 1x and 2x:
//   swift make_dmg_background.swift <out-prefix> <width> <height> <appX> <appsX> <iconY>
// → <out-prefix>.png and <out-prefix>@2x.png. Sizes and positions are in points, y from the top,
// matching the Finder window layout set up in build.sh.
//
// No text on purpose: the arrow alone says "drag to Applications" in any language.
//
// Finder draws icon labels black in light mode and white in dark mode, so the band behind the labels
// is kept mid-tone: readable in both.
import AppKit

let args = CommandLine.arguments
let prefix = args[1]
let width = CGFloat(Double(args[2])!), height = CGFloat(Double(args[3])!)
let appX = CGFloat(Double(args[4])!), appsX = CGFloat(Double(args[5])!), iconY = CGFloat(Double(args[6])!)
let space = CGColorSpaceCreateDeviceRGB()
let bleed: CGFloat = 40  // extra canvas below the window, shown only if the title bar is shorter than expected

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int((height + bleed) * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height + bleed)  // 144 dpi for @2x, which tiffutil -cathidpicheck expects
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // Drawing below uses points with y going down from the top, like Finder.
    ctx.translateBy(x: 0, y: height + bleed)
    ctx.scaleBy(x: 1, y: -1)

    // Night sky on top fading into a lighter violet where the icon labels sit.
    let base = CGGradient(colorsSpace: space, colors: [rgb(0x1E1752), rgb(0x3A2E8C), rgb(0x6A5CC8)] as CFArray,
                          locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: height), options: [.drawsAfterEndLocation])

    func glow(_ center: CGPoint, _ radius: CGFloat, _ color: UInt32, _ alpha: CGFloat) {
        let g = CGGradient(colorsSpace: space, colors: [rgb(color, alpha), rgb(color, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }
    glow(CGPoint(x: width * 0.12, y: height * 0.15), width * 0.45, 0x7B5CFF, 0.55)
    glow(CGPoint(x: width * 0.92, y: height * 0.95), width * 0.5, 0x1FC8D8, 0.38)
    glow(CGPoint(x: width * 0.85, y: height * 0.05), width * 0.3, 0xF07AAA, 0.22)

    // Faint stars in the dark upper part.
    var seed: UInt64 = 7
    func random() -> CGFloat {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(seed >> 33) / CGFloat(1 << 31)
    }
    for _ in 0..<46 {
        let p = CGPoint(x: random() * width, y: random() * height * 0.55)
        let r = 0.4 + random() * 0.9
        ctx.setFillColor(rgb(0xFFFFFF, 0.15 + random() * 0.4 * (1 - p.y / (height * 0.55))))
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }

    // Arrow from the app to Applications: a gentle arch with a rounded head.
    let iconHalf: CGFloat = 64, pad: CGFloat = 22
    let start = CGPoint(x: appX + iconHalf + pad, y: iconY + 4)
    let end = CGPoint(x: appsX - iconHalf - pad, y: iconY + 4)
    let control = CGPoint(x: (start.x + end.x) / 2, y: iconY - 26)
    let shaft = CGMutablePath()
    shaft.move(to: start)
    shaft.addQuadCurve(to: end, control: control)
    // Arrowhead aligned with the curve's end tangent.
    let angle = atan2(end.y - control.y, end.x - control.x)
    let headLength: CGFloat = 15, spread: CGFloat = .pi / 4.6
    let head = CGMutablePath()
    head.move(to: CGPoint(x: end.x - headLength * cos(angle - spread), y: end.y - headLength * sin(angle - spread)))
    head.addLine(to: end)
    head.addLine(to: CGPoint(x: end.x - headLength * cos(angle + spread), y: end.y - headLength * sin(angle + spread)))

    let arrow = CGMutablePath()
    arrow.addPath(shaft)
    arrow.addPath(head)
    let stroked = arrow.copy(strokingWithWidth: 5, lineCap: .round, lineJoin: .round, miterLimit: 10)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 16, color: rgb(0xA8C8FF, 0.7))
    ctx.addPath(stroked)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(stroked)
    ctx.clip()
    let fill = CGGradient(colorsSpace: space, colors: [rgb(0xE4E0FF), rgb(0xFFFFFF), rgb(0xC9F4FA)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(fill, start: CGPoint(x: start.x, y: 0), end: CGPoint(x: end.x, y: 0), options: [])
    ctx.restoreGState()

    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

try! render(scale: 1).write(to: URL(fileURLWithPath: prefix + ".png"))
try! render(scale: 2).write(to: URL(fileURLWithPath: prefix + "@2x.png"))
