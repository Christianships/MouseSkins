// Renders the cursor half of docs/demo.gif from a real .cape skin.
// Usage: swiftc -O docs/make-demo.swift -o /tmp/make-demo && /tmp/make-demo <skin.cape> <out-dir>
// then add panel screenshots (`MouseSkins --panel --tab Home`, etc.) and assemble with ffmpeg.

let capeURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outDir = CommandLine.arguments[2]
let W = 900, H = 720, fps = 25.0

struct Cur { let frames: [CGImage]; let hot: CGPoint; let pts: CGSize; let dur: Double }
let plist = try! PropertyListSerialization.propertyList(from: Data(contentsOf: capeURL), format: nil) as! [String: Any]
let cursors = plist["Cursors"] as! [String: [String: Any]]
func load(_ ident: String) -> Cur {
    let c = cursors[ident]!
    let reps = (c["Representations"] as! [Data]).compactMap { NSBitmapImageRep(data: $0)?.cgImage }
    let sheet = reps.max { $0.width < $1.width }!
    let n = (c["FrameCount"] as! NSNumber).intValue
    let h = sheet.height / n
    let frames = (0..<n).map { sheet.cropping(to: CGRect(x: 0, y: $0 * h, width: sheet.width, height: h))! }
    return Cur(frames: frames, hot: CGPoint(x: (c["HotSpotX"] as! NSNumber).doubleValue, y: (c["HotSpotY"] as! NSNumber).doubleValue),
               pts: CGSize(width: (c["PointsWide"] as! NSNumber).doubleValue, height: (c["PointsHigh"] as! NSNumber).doubleValue),
               dur: (c["FrameDuration"] as! NSNumber).doubleValue)
}
let arrow = load("com.apple.coregraphics.Arrow"), hand = load("com.apple.cursor.13"),
    ibeam = load("com.apple.coregraphics.IBeam"), wait = load("com.apple.coregraphics.Wait"),
    resize = load("com.apple.cursor.28")

// Timeline: (time, position, cursor, label)
let win = CGRect(x: 150, y: 150, width: 600, height: 380)      // top-left origin
let button = CGRect(x: win.minX + 40, y: win.maxY - 90, width: 170, height: 50)
struct Key { let t: Double; let p: CGPoint }
let path: [Key] = [
    Key(t: 0.0, p: CGPoint(x: 80, y: 640)), Key(t: 1.3, p: CGPoint(x: 420, y: 330)),        // arrow over desktop/window
    Key(t: 2.3, p: CGPoint(x: button.midX, y: button.midY)), Key(t: 4.6, p: CGPoint(x: button.midX, y: button.midY)), // hand, click, wait
    Key(t: 5.6, p: CGPoint(x: win.minX + 60, y: win.minY + 130)), Key(t: 7.0, p: CGPoint(x: win.minX + 480, y: win.minY + 130)), // ibeam sweep
    Key(t: 8.0, p: CGPoint(x: win.maxX, y: win.midY + 20)), Key(t: 9.4, p: CGPoint(x: win.maxX + 40, y: win.midY + 20)), // resize
    Key(t: 10.0, p: CGPoint(x: win.maxX + 40, y: win.midY + 20)),
]
let total = 10.0
func pos(_ t: Double) -> CGPoint {
    for i in 0..<(path.count - 1) where t <= path[i + 1].t {
        let a = path[i], b = path[i + 1]
        var u = (t - a.t) / max(b.t - a.t, 0.0001); u = u * u * (3 - 2 * u)
        return CGPoint(x: a.p.x + (b.p.x - a.p.x) * u, y: a.p.y + (b.p.y - a.p.y) * u)
    }
    return path.last!.p
}
func state(_ t: Double) -> (Cur, String) {
    switch t {
    case ..<2.0: return (arrow, "Normal Select")
    case ..<3.0: return (hand, "Link Select")
    case ..<4.8: return (wait, "Busy")
    case ..<5.4: return (arrow, "Normal Select")
    case ..<7.6: return (ibeam, "Text Select")
    default: return (resize, "Resize")
    }
}

func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, at p: CGPoint) {
    (s as NSString).draw(at: p, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
}

let frameCount = Int(total * fps)
for f in 0..<frameCount {
    let t = Double(f) / fps
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    let cg = g.cgContext
    cg.translateBy(x: 0, y: CGFloat(H)); cg.scaleBy(x: 1, y: -1)          // top-left origin
    let flipped = NSGraphicsContext(cgContext: cg, flipped: true); NSGraphicsContext.current = flipped

    // desktop
    NSGradient(colors: [NSColor(red: 0.80, green: 0.70, blue: 0.98, alpha: 1), NSColor(red: 0.52, green: 0.33, blue: 0.86, alpha: 1)])!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)
    // window
    let shadow = NSShadow(); shadow.shadowBlurRadius = 30; shadow.shadowOffset = NSSize(width: 0, height: -10); shadow.shadowColor = .black.withAlphaComponent(0.3)
    NSGraphicsContext.saveGraphicsState(); shadow.set()
    NSColor(white: 0.98, alpha: 1).setFill(); NSBezierPath(roundedRect: win, xRadius: 16, yRadius: 16).fill()
    NSGraphicsContext.restoreGraphicsState()
    for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
        c.setFill(); NSBezierPath(ovalIn: NSRect(x: win.minX + 20 + CGFloat(i) * 22, y: win.minY + 18, width: 13, height: 13)).fill()
    }
    text("Minecraft Netherite", 26, .bold, NSColor(white: 0.1, alpha: 1), at: CGPoint(x: win.minX + 40, y: win.minY + 55))
    let body = ["Custom cursor skins for your whole Mac.", "Pick one, hit apply, and every app uses it,",
                "from the desktop to text fields to links."]
    // highlight "selected" text during the ibeam sweep
    if t > 5.6 && t < 7.8 {
        let sel = pos(min(t, 7.0)).x - (win.minX + 60)
        NSColor(red: 0.66, green: 0.33, blue: 0.97, alpha: 0.28).setFill()
        NSBezierPath(rect: NSRect(x: win.minX + 60, y: win.minY + 116, width: max(sel, 0), height: 28)).fill()
    }
    for (i, line) in body.enumerated() {
        text(line, 19, .regular, NSColor(white: 0.3, alpha: 1), at: CGPoint(x: win.minX + 40, y: win.minY + 115 + CGFloat(i) * 32))
    }
    let pressed = t > 2.9 && t < 3.1
    let hover = t > 2.0 && t < 4.8
    NSColor(red: 0.66, green: 0.33, blue: 0.97, alpha: hover ? 1 : 0.8).setFill()
    NSBezierPath(roundedRect: pressed ? button.insetBy(dx: 3, dy: 2) : button, xRadius: 12, yRadius: 12).fill()
    text(t > 3.0 && t < 4.8 ? "Applying…" : "Apply skin", 19, .semibold, .white, at: CGPoint(x: button.minX + 30, y: button.minY + 13))

    // caption
    let (cur, label) = state(t)
    let cap = NSRect(x: CGFloat(W) / 2 - 130, y: CGFloat(H) - 80, width: 260, height: 44)
    NSColor.black.withAlphaComponent(0.45).setFill(); NSBezierPath(roundedRect: cap, xRadius: 22, yRadius: 22).fill()
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 19, weight: .semibold), .foregroundColor: NSColor.white]
    let size = (label as NSString).size(withAttributes: attrs)
    (label as NSString).draw(at: CGPoint(x: cap.midX - size.width / 2, y: cap.midY - size.height / 2), withAttributes: attrs)

    // cursor: 3x its point size, nearest-neighbour so the pixel art stays crisp
    let scale: CGFloat = 3
    let frame = cur.frames[cur.frames.count > 1 && cur.dur > 0 ? Int(t / cur.dur) % cur.frames.count : 0]
    let p = pos(t)
    let r = CGRect(x: p.x - cur.hot.x * scale, y: p.y - cur.hot.y * scale, width: cur.pts.width * scale, height: cur.pts.height * scale)
    cg.interpolationQuality = .none
    cg.saveGState(); cg.translateBy(x: r.minX, y: r.maxY); cg.scaleBy(x: 1, y: -1)
    cg.setShadow(offset: CGSize(width: 0, height: -4), blur: 8, color: CGColor(gray: 0, alpha: 0.5))
    cg.draw(frame, in: CGRect(origin: .zero, size: r.size)); cg.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: String(format: "%@/%04d.png", outDir, f)))
}
print("rendered \(frameCount) frames")
