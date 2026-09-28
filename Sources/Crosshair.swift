import CoreGraphics

/// A thin Minecraft-style "+" on the hotspot of the Normal and Link Select
/// cursors, so it's clear exactly where a click lands. Like the game's: no
/// outline, one pixel thick. A cursor can't invert what's under it the way
/// the game does, so it's a light gray that reads on most backgrounds.
enum Crosshair {
    static let arm: CGFloat = 6             // points from the hotspot to each tip
    static let thickness: CGFloat = 0.5     // one pixel on a Retina display
    static let pad = arm + 1

    /// Normal Select + Link Select, plus the aliases macOS 26 draws the pointer from.
    static var targets: Set<String> {
        let idents = CursorGroup.all.filter { ["Normal Select", "Link Select"].contains($0.name) }.flatMap(\.idents)
        return Set(idents + idents.flatMap { Cursors.synonyms(of: $0) })
    }

    /// The cursor with the plus drawn over it. The canvas grows left/up when
    /// the hotspot sits near the edge (a sword's is its top-left tip).
    static func add(to c: Cursor) -> Cursor {
        let w = c.size.width, h = c.size.height
        guard w > 0, h > 0 else { return c }
        let off = CGPoint(x: max(pad - c.hotSpot.x, 0), y: max(pad - c.hotSpot.y, 0))
        let hot = CGPoint(x: c.hotSpot.x + off.x, y: c.hotSpot.y + off.y)
        let size = CGSize(width: max(w + off.x, hot.x + pad + 1), height: max(h + off.y, hot.y + pad + 1))
        let frames = max(c.frameCount, 1)

        let images: [CGImage] = c.images.compactMap { rep in
            let k = CGFloat(rep.width) / w                  // pixels per point for this rep
            let fh = rep.height / frames
            let cw = Int(size.width * k), ch = Int(size.height * k)
            guard let ctx = context(cw, ch * frames), let plus = image(k: k) else { return nil }
            ctx.interpolationQuality = .none
            // CG's origin is bottom-left and frames stack top to bottom.
            for i in 0..<frames {
                guard let frame = rep.cropping(to: CGRect(x: 0, y: i * fh, width: rep.width, height: fh)) else { continue }
                let bottom = CGFloat(ch * (frames - 1 - i))
                ctx.draw(frame, in: CGRect(x: off.x * k, y: bottom + CGFloat(ch) - off.y * k - CGFloat(fh),
                                           width: CGFloat(rep.width), height: CGFloat(fh)))
                let p = CGFloat(plus.width)
                ctx.draw(plus, in: CGRect(x: (hot.x - pad) * k, y: bottom + CGFloat(ch) - (hot.y - pad) * k - p,
                                          width: p, height: p))
            }
            return ctx.makeImage()
        }
        guard images.count == c.images.count else { return c }
        return Cursor(size: size, hotSpot: hot, frameCount: c.frameCount, frameDuration: c.frameDuration, images: images)
    }

    /// Just the plus, `2·pad + 1` points square at `k` pixels per point; the
    /// hotspot is at (pad, pad) from the top-left.
    static func image(k: CGFloat) -> CGImage? {
        let side = Int((pad * 2 + 1) * k)
        guard let ctx = context(side, side) else { return nil }
        let t = max(thickness, 1 / k)                       // never thinner than a device pixel
        let bars = [CGRect(x: pad, y: pad - arm, width: t, height: arm * 2 + t),
                    CGRect(x: pad - arm, y: pad, width: arm * 2 + t, height: t)]
        // Top-left-origin points → CG pixels.
        ctx.setFillColor(CGColor(gray: 0.78, alpha: 0.95))
        ctx.fill(bars.map { CGRect(x: $0.minX * k, y: CGFloat(side) - $0.maxY * k, width: $0.width * k, height: $0.height * k) })
        return ctx.makeImage()
    }

    private static func context(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
