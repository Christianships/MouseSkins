import AppKit
import QuartzCore

/// Swing on click: on every left mouse-down, if the pointer is showing the
/// theme's Normal Select or Link Select cursor, it plays one Minecraft-style
/// swing (wind up to the right, sweep across to the left, back to rest).
///
/// Swapping registered cursors can't do this: WindowServer only redraws the
/// pointer when the app under it re-sets its cursor, so the swing would be
/// missed or stuck looping. Instead the real pointer is hidden for the length
/// of the swing and the sword is drawn in a click-through overlay that Core
/// Animation rotates around the grip.
enum Swing {
    /// Rotation (degrees, counter-clockwise from rest) and when it's reached
    /// (fraction of `duration`).
    static let angles: [CGFloat] = [0, -40, 100, 0]
    static let times: [NSNumber] = [0, 0.12, 0.55, 1]
    static let duration: CFTimeInterval = 0.18

    private struct Sword {
        var size: CGSize
        var hotSpot: CGPoint
        var frames: [CGImage]           // sharpest rep, split into frames
        var frameDuration: CGFloat
        var print: [UInt8]              // for matching against the live cursor
    }

    private static var swords: [Sword] = []     // Normal Select, Link Select
    private static var others: [[UInt8]] = []   // the theme's other cursors, so they don't match a sword
    private static var monitors: [Any] = []
    private static var window: NSWindow?
    private static let layer = CALayer()
    private static var follow: Timer?
    private static var generation = 0          // bumps per click; stale timers check it
    private static var configured: Int?         // sword the overlay is set up for
    /// The pointer and the resting sword overlap this long at each end of a
    /// swing, so a late frame never leaves neither on screen.
    static let lead: TimeInterval = 0.025
    static let tail: TimeInterval = 0.05
    private static var active = false           // sword showing in the overlay
    private static var hidden = false
    private static var showing = 0              // index into swords of the one on screen
    private static var grip = CGPoint.zero      // grip offset from the hotspot, in screen points

    /// Rebuilds from the saved state; starts or stops the monitor.
    static func update() {
        configured = nil
        if !active { window?.orderOut(nil) }    // re-shown on the next swing
        swords = []
        others = []
        let s = Store.state
        if s.swing == true, let id = s.theme, let theme = try? Store.theme(id) {
            let lefty = s.leftHanded == true
            var used = Set<String>()
            for name in ["Normal Select", "Link Select"] {
                guard let g = CursorGroup.all.first(where: { $0.name == name }) else { continue }
                used.formUnion(g.idents)
                guard let ident = g.idents.first(where: { theme.cursors[$0] != nil }),
                      var c = theme.cursors[ident] else { continue }
                if lefty && Cursors.mirrorable.contains(ident) { c = Cursors.mirrored(c) }
                if let sword = sword(c) { swords.append(sword) }
            }
            others = theme.cursors.filter { !used.contains($0.key) }.values.compactMap { sword($0)?.print }
        }
        if swords.isEmpty {
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
        } else if monitors.isEmpty {
            // Mouse-down global monitors need no Accessibility/Input Monitoring grant.
            if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { _ in play() }) {
                monitors.append(m)
            }
            monitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { play(); return $0 } as Any)
        }
    }

    private static func play() {
        // Mid-swing the pointer is hidden, so reuse the sword already on screen.
        if !hidden || !swords.indices.contains(showing) {
            guard let i = current() else { return }
            showing = i
        }
        let sword = swords[showing]

        let scale = CGFloat(Cursors.scale)
        let size = CGSize(width: sword.size.width * scale, height: sword.size.height * scale)
        let hot = CGPoint(x: sword.hotSpot.x * scale, y: sword.hotSpot.y * scale)
        // Rotate around the grip: 80% of the way from the hotspot to the far corner.
        let gripInImage = CGPoint(x: hot.x + (size.width - hot.x) * 0.8, y: hot.y + (size.height - hot.y) * 0.8)
        grip = CGPoint(x: gripInImage.x - hot.x, y: gripInImage.y - hot.y)
        let reach = ceil(hypot(max(gripInImage.x, size.width - gripInImage.x),
                               max(gripInImage.y, size.height - gripInImage.y)))

        let win = window ?? makeWindow()
        generation += 1
        let gen = generation
        // A repeat tap only restarts the spin; rebuilding a visible overlay flickers.
        if !active || configured != showing {
            configured = showing
            win.setContentSize(CGSize(width: reach * 2, height: reach * 2))
            move()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeAllAnimations()
            layer.bounds = CGRect(origin: .zero, size: size)
            // Layer coordinates are bottom-left, image coordinates top-left.
            layer.anchorPoint = CGPoint(x: gripInImage.x / size.width, y: 1 - gripInImage.y / size.height)
            layer.position = CGPoint(x: reach, y: reach)
            layer.contents = sword.frames[0]
            layer.contentsScale = CGFloat(sword.frames[0].width) / size.width
            if sword.frames.count > 1 {         // keep an enchant glint moving
                let glint = CAKeyframeAnimation(keyPath: "contents")
                glint.values = sword.frames
                glint.calculationMode = .discrete
                glint.duration = Double(sword.frameDuration) * Double(sword.frames.count)
                glint.repeatCount = .infinity
                layer.add(glint, forKey: "glint")
            }
            layer.isHidden = false
            CATransaction.commit()
            if !win.isVisible { win.orderFrontRegardless() }
            follow?.invalidate()
            follow = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { _ in move() }
            active = true
        }

        // From rest, hold the resting pose (identical to the pointer) until the
        // pointer is hidden, then swing. Mid-swing taps restart straight away.
        let delay = hidden ? 0 : lead
        let spin = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        spin.values = angles.map { $0 * .pi / 180 }
        spin.keyTimes = times
        spin.timingFunctions = [.init(name: .easeOut), .init(name: .easeIn), .init(name: .easeOut)]
        spin.duration = duration
        spin.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
        spin.fillMode = .backwards
        layer.add(spin, forKey: "swing")       // replaces a swing in progress

        if !hidden {
            DispatchQueue.main.asyncAfter(deadline: .now() + lead) {
                guard active, !hidden else { return }
                CGDisplayHideCursor(CGMainDisplayID())
                hidden = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + duration) {
            guard gen == generation else { return }
            if hidden {
                CGDisplayShowCursor(CGMainDisplayID())
                hidden = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + tail) {
                guard gen == generation else { return }
                follow?.invalidate()
                follow = nil
                // The window stays up (transparent, click-through): putting a
                // window back on screen is slower than showing a layer.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.isHidden = true
                CATransaction.commit()
                active = false
            }
        }
    }

    /// Keeps the overlay's grip where the real pointer's grip would be.
    private static func move() {
        guard let win = window else { return }
        let m = NSEvent.mouseLocation   // screen coordinates, y up
        let half = win.frame.width / 2
        win.setFrameOrigin(CGPoint(x: m.x + grip.x - half, y: m.y - grip.y - half))
    }

    private static func makeWindow() -> NSWindow {
        // A background app may only hide the pointer with this connection property set.
        CGSSetConnectionProperty(Cursors.cid, Cursors.cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        let w = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)))
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView()
        view.wantsLayer = true
        layer.magnificationFilter = .nearest    // keep pixel art crisp
        layer.minificationFilter = .nearest
        layer.isHidden = true
        view.layer?.addSublayer(layer)
        w.contentView = view
        window = w
        return w
    }

    /// Index of the sword matching the pointer on screen right now, if it's one of ours.
    private static func current() -> Int? {
        guard let live = NSCursor.currentSystem,
              let img = live.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let p = fingerprint(img) else { return swords.isEmpty ? nil : 0 }
        guard let best = swords.indices.min(by: { distance(swords[$0].print, p) < distance(swords[$1].print, p) })
        else { return nil }
        // Pointer is some other cursor (text, resize…) → no swing.
        if let other = others.min(by: { distance($0, p) < distance($1, p) }),
           distance(other, p) < distance(swords[best].print, p) { return nil }
        return best
    }

    private static func sword(_ c: Cursor) -> Sword? {
        guard let rep = c.images.max(by: { $0.width < $1.width }), c.frameCount >= 1 else { return nil }
        let fh = rep.height / c.frameCount
        let frames = (0..<c.frameCount).compactMap {
            rep.cropping(to: CGRect(x: 0, y: $0 * fh, width: rep.width, height: fh))
        }
        guard let first = frames.first, let p = fingerprint(first) else { return nil }
        return Sword(size: c.size, hotSpot: c.hotSpot, frames: frames, frameDuration: c.frameDuration, print: p)
    }

    /// A 16×16 RGBA thumbnail (of the top frame, for animated strips).
    private static func fingerprint(_ img: CGImage) -> [UInt8]? {
        let n = 16
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let src = img.height > img.width * 3 / 2
            ? img.cropping(to: CGRect(x: 0, y: 0, width: img.width, height: img.width)) ?? img : img
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(src, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        return ok ? px : nil
    }

    private static func distance(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
    }
}
