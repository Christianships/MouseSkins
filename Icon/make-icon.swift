// Draws the app icon: a violet squircle with a white pointer and rays.
// Usage: swift Icon/make-icon.swift Icon/AppIcon.iconset && iconutil -c icns Icon/AppIcon.iconset
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Drawn top-down in a 1024 grid.
    ctx.translateBy(x: 0, y: s); ctx.scaleBy(x: s / 1024, y: -s / 1024)

    // macOS icon grid: 824pt body inset 100pt, continuous-ish corners.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
    let grad = CGGradient(colorsSpace: rgb, colors: [
        CGColor(red: 0.66, green: 0.33, blue: 0.97, alpha: 1),     // #A855F7
        CGColor(red: 0.29, green: 0.11, blue: 0.55, alpha: 1),
        CGColor(red: 0.09, green: 0.04, blue: 0.19, alpha: 1),
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 180, y: 100), end: CGPoint(x: 844, y: 924), options: [])
    // soft glow behind the pointer
    let glow = CGGradient(colorsSpace: rgb, colors: [CGColor(red: 0.91, green: 0.47, blue: 0.98, alpha: 0.55),
                                                      CGColor(red: 0.91, green: 0.47, blue: 0.98, alpha: 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 470, y: 470), startRadius: 0,
                           endCenter: CGPoint(x: 470, y: 470), endRadius: 380, options: [])
    ctx.restoreGState()

    // rays around the tip
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
    ctx.setLineWidth(30); ctx.setLineCap(.round)
    let tip = CGPoint(x: 400, y: 330)
    for (angle, r0, r1) in [(-150.0, 70.0, 150.0), (-110.0, 70.0, 165.0), (-70.0, 80.0, 150.0), (180.0, 75.0, 150.0)] {
        let a = angle * .pi / 180
        ctx.move(to: CGPoint(x: tip.x + cos(a) * r0, y: tip.y + sin(a) * r0))
        ctx.addLine(to: CGPoint(x: tip.x + cos(a) * r1, y: tip.y + sin(a) * r1))
    }
    ctx.strokePath()

    // the pointer (classic arrow proportions), tip at `tip`
    let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, 400), (95, 308), (165, 470), (232, 441), (163, 283), (292, 283)]
    let arrow = CGMutablePath()
    arrow.addLines(between: pts.map { CGPoint(x: tip.x + $0.0, y: tip.y + $0.1) })
    arrow.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 30, color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(arrow); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(arrow)
    ctx.setStrokeColor(CGColor(red: 0.09, green: 0.04, blue: 0.19, alpha: 1)); ctx.setLineWidth(22); ctx.setLineJoin(.round)
    ctx.strokePath()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
