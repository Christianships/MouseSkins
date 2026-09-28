import CoreGraphics

/// Cursors grouped by what they're for, with Windows-style role names (the way
/// Mousecape presents them). A theme usually draws one image per group, so the
/// editor edits a group at once.
struct CursorGroup: Identifiable {
    let name: String
    let keys: [String]          // friendly names from Cursors.names
    var id: String { name }
    var idents: [String] { keys.compactMap { Cursors.names[$0] } }

    static let all: [CursorGroup] = [
        .init(name: "Normal Select", keys: ["arrow", "context-arrow", "context-menu"]),
        .init(name: "Link Select", keys: ["pointing", "link"]),
        .init(name: "Text Select", keys: ["ibeam", "ibeam-xor", "ibeam-horizontal"]),
        .init(name: "Busy", keys: ["wait"]),
        .init(name: "Working in Background", keys: ["busy"]),
        .init(name: "Help Select", keys: ["help"]),
        .init(name: "Precision Select", keys: ["crosshair", "crosshair-2", "cell", "cell-xor"]),
        .init(name: "Unavailable", keys: ["forbidden"]),
        .init(name: "Move", keys: ["move", "resize-square"]),
        .init(name: "Grab", keys: ["open-hand", "closed-hand"]),
        .init(name: "Vertical Resize", keys: ["resize-n", "resize-s", "resize-n-s", "window-n", "window-s", "window-n-s"]),
        .init(name: "Horizontal Resize", keys: ["resize-w", "resize-e", "resize-w-e", "window-w", "window-e", "window-e-w"]),
        .init(name: "Diagonal Resize ↖↘", keys: ["window-nw", "window-se", "window-nw-se"]),
        .init(name: "Diagonal Resize ↗↙", keys: ["window-ne", "window-sw", "window-ne-sw"]),
        .init(name: "Copy & Alias", keys: ["copy", "copy-drag", "alias"]),
        .init(name: "Zoom", keys: ["zoom-in", "zoom-out"]),
        .init(name: "Screenshot", keys: ["camera", "camera-2"]),
        .init(name: "Other", keys: ["poof", "counting-up", "counting-down", "counting-up-down", "empty"]),
    ]

    /// The groups this theme has at least one cursor for, each narrowed to the
    /// identifiers the theme defines. Unknown identifiers land in "Other".
    static func present(in theme: Theme) -> [CursorGroup] {
        var seen = Set<String>()
        var out: [CursorGroup] = []
        for g in all {
            let keys = g.keys.filter { Cursors.names[$0].map { theme.cursors[$0] != nil } ?? false }
            seen.formUnion(keys.compactMap { Cursors.names[$0] })
            if !keys.isEmpty { out.append(.init(name: g.name, keys: keys)) }
        }
        let extra = theme.cursors.keys.filter { !seen.contains($0) }.sorted()
        if !extra.isEmpty {
            // Unknown identifiers keep their raw name as the key.
            if let i = out.firstIndex(where: { $0.name == "Other" }) {
                out[i] = .init(name: "Other", keys: out[i].keys + extra)
            } else {
                out.append(.init(name: "Other", keys: extra))
            }
        }
        return out
    }

    /// Identifiers in this group for a theme (handles raw identifiers in "Other").
    func idents(in theme: Theme) -> [String] {
        keys.compactMap { Cursors.names[$0] ?? (theme.cursors[$0] != nil ? $0 : nil) }
    }
}

extension Cursors {
    /// Pointer-style cursors that flip in left-hand mode (resize/crosshair/text
    /// shapes are symmetric or directional, so they stay put).
    static let mirrorable: Set<String> = Set(["arrow", "context-arrow", "context-menu", "pointing", "link",
                                              "busy", "help", "copy", "copy-drag", "alias", "forbidden"]
                                              .compactMap { names[$0] }
                                             + ["com.apple.coregraphics.ArrowS"])

    static func mirrored(_ c: Cursor) -> Cursor {
        var m = c
        m.hotSpot.x = max(c.size.width - c.hotSpot.x - 1, 0)
        m.images = c.images.map { img in
            guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
            ctx.translateBy(x: CGFloat(img.width), y: 0)
            ctx.scaleBy(x: -1, y: 1)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            return ctx.makeImage() ?? img
        }
        return m
    }
}
