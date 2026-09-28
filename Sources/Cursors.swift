import AppKit

/// Thin wrapper over the private WindowServer cursor calls in CGSPrivate.h.
enum Cursors {
    static let cid = CGSMainConnectionID()

    /// The named cursors WindowServer draws itself. They survive
    /// CoreCursorUnregisterAll, so reset restores them from the saved defaults.
    static let coreGraphics = [
        "com.apple.coregraphics.Arrow",
        "com.apple.coregraphics.IBeam",
        "com.apple.coregraphics.IBeamXOR",
        "com.apple.coregraphics.Alias",
        "com.apple.coregraphics.Copy",
        "com.apple.coregraphics.Move",
        "com.apple.coregraphics.ArrowCtx",
        "com.apple.coregraphics.ArrowS",
        "com.apple.coregraphics.IBeamS",
        "com.apple.coregraphics.Wait",
        "com.apple.coregraphics.Empty",
    ]

    /// Since macOS 26 WindowServer draws the pointer from more than one name
    /// (e.g. ArrowS alongside Arrow), so a theme's Arrow/IBeam also goes to every
    /// system cursor named like it that the theme doesn't define itself.
    static func synonyms(of ident: String) -> [String] {
        let word = ident.hasSuffix(".Arrow") ? "arrow" : ident.hasSuffix(".IBeam") ? "ibeam" : nil
        guard let word else { return [] }
        let system = (0..<128).compactMap { CGSCursorNameForSystemCursor(Int32($0)).map { String(cString: $0) } }
        return system.filter { $0 != ident && $0.lowercased().contains(word) }
    }

    /// Registered alongside every applied theme. WindowServer registrations
    /// last until logout, so this tells us the session is already themed.
    static let marker = "dev.mouseskins.applied"
    static let legacyMarker = "dev.msig.applied"    // same thing, from before the rename

    /// Friendly names for theme.json keys, following Mousecape's labels.
    static let names: [String: String] = [
        "arrow": "com.apple.coregraphics.Arrow",
        "ibeam": "com.apple.coregraphics.IBeam",
        "ibeam-xor": "com.apple.coregraphics.IBeamXOR",
        "alias": "com.apple.coregraphics.Alias",
        "copy": "com.apple.coregraphics.Copy",
        "move": "com.apple.coregraphics.Move",
        "context-arrow": "com.apple.coregraphics.ArrowCtx",
        "wait": "com.apple.coregraphics.Wait",
        "empty": "com.apple.coregraphics.Empty",
        "link": "com.apple.cursor.2",
        "forbidden": "com.apple.cursor.3",
        "busy": "com.apple.cursor.4",
        "copy-drag": "com.apple.cursor.5",
        "crosshair": "com.apple.cursor.7",
        "crosshair-2": "com.apple.cursor.8",
        "camera-2": "com.apple.cursor.9",
        "camera": "com.apple.cursor.10",
        "closed-hand": "com.apple.cursor.11",
        "open-hand": "com.apple.cursor.12",
        "pointing": "com.apple.cursor.13",
        "counting-up": "com.apple.cursor.14",
        "counting-down": "com.apple.cursor.15",
        "counting-up-down": "com.apple.cursor.16",
        "resize-w": "com.apple.cursor.17",
        "resize-e": "com.apple.cursor.18",
        "resize-w-e": "com.apple.cursor.19",
        "cell-xor": "com.apple.cursor.20",
        "resize-n": "com.apple.cursor.21",
        "resize-s": "com.apple.cursor.22",
        "resize-n-s": "com.apple.cursor.23",
        "context-menu": "com.apple.cursor.24",
        "poof": "com.apple.cursor.25",
        "ibeam-horizontal": "com.apple.cursor.26",
        "window-e": "com.apple.cursor.27",
        "window-e-w": "com.apple.cursor.28",
        "window-ne": "com.apple.cursor.29",
        "window-ne-sw": "com.apple.cursor.30",
        "window-n": "com.apple.cursor.31",
        "window-n-s": "com.apple.cursor.32",
        "window-nw": "com.apple.cursor.33",
        "window-nw-se": "com.apple.cursor.34",
        "window-s": "com.apple.cursor.35",
        "window-se": "com.apple.cursor.36",
        "window-sw": "com.apple.cursor.37",
        "window-w": "com.apple.cursor.38",
        "resize-square": "com.apple.cursor.39",
        "help": "com.apple.cursor.40",
        "cell": "com.apple.cursor.41",
        "zoom-in": "com.apple.cursor.42",
        "zoom-out": "com.apple.cursor.43",
    ]

    static func isRegistered(_ name: String) -> Bool {
        var size = 0
        return CGSGetRegisteredCursorDataSize(cid, name, &size) == .success && size > 0
    }

    @discardableResult
    static func register(_ name: String, _ c: Cursor) -> Bool {
        guard (1...24).contains(c.frameCount), !c.images.isEmpty else { return false }
        // Hotspots at or past the edge make WindowServer reject the cursor.
        let hot = CGPoint(x: min(max(c.hotSpot.x, 0), 31.99), y: min(max(c.hotSpot.y, 0), 31.99))
        var seed: Int32 = 0
        return CGSRegisterCursorWithImages(cid, name, true, true, c.size, hot,
                                           UInt(c.frameCount), c.frameDuration,
                                           c.images as CFArray, &seed) == .success
    }

    static func copyRegistered(_ name: String) -> Cursor? {
        guard isRegistered(name) else { return nil }
        var size = CGSize.zero, hot = CGPoint.zero
        var frames: UInt = 0, duration: CGFloat = 0
        var images: Unmanaged<CFArray>?
        guard CGSCopyRegisteredCursorImages(cid, name, &size, &hot, &frames, &duration, &images) == .success,
              let array = images?.takeRetainedValue() as? [CGImage] else { return nil }
        return Cursor(size: size, hotSpot: hot, frameCount: Int(frames), frameDuration: duration, images: array)
    }

    /// The stock Arrow/IBeam/etc. only exist inside WindowServer: once a theme
    /// overrides them there's no way to ask for the originals back until logout,
    /// and they can't be unregistered either. So MouseSkins saves them to disk once,
    /// from a session nothing has themed yet, and reset re-registers that copy.
    static var hasSavedDefaults: Bool { FileManager.default.fileExists(atPath: Store.defaultsURL.path) }

    /// Returns true if it saved them. Skips when a theme (MouseSkins' marker, or a
    /// running Mousecape helper) may already have replaced them this session.
    @discardableResult
    static func captureDefaultsIfClean() -> Bool {
        guard !hasSavedDefaults, !isRegistered(marker), !isRegistered(legacyMarker),
              !NSWorkspace.shared.runningApplications.contains(where: {
                  $0.bundleIdentifier?.lowercased().contains("mousecape") == true })
        else { return false }
        var found: [String: Cursor] = [:]
        for ident in coreGraphics { found[ident] = copyRegistered(ident) }
        guard found["com.apple.coregraphics.Arrow"] != nil else { return false }
        return (try? Theme.writeCape(found, name: "macOS Default", to: Store.defaultsURL)) != nil
    }

    /// Back to the stock macOS cursors. The numbered com.apple.cursor.* ones
    /// fall back by themselves; the coregraphics ones need the saved copy.
    static func reset() {
        if let saved = try? Theme.loadCape(Store.defaultsURL) {
            for (ident, c) in saved.cursors { register(ident, c) }
        }
        if CoreCursorUnregisterAll(cid) == .success {
            for x in 0..<45 { CoreCursorSet(cid, Int32(x)) }
        }
        CGSRemoveRegisteredCursor(cid, marker, false)
        refresh()
    }

    /// Returns the identifiers that failed to register.
    @discardableResult
    static func apply(_ theme: Theme) -> [String] {
        captureDefaultsIfClean()
        reset()
        let lefty = Store.state.leftHanded == true
        let flip = { (ident: String, c: Cursor) in lefty && mirrorable.contains(ident) ? mirrored(c) : c }
        let failed = theme.cursors.filter { !register($0.key, flip($0.key, $0.value)) }.map(\.key)
        for (ident, c) in theme.cursors {
            for alias in synonyms(of: ident) where theme.cursors[alias] == nil { register(alias, flip(alias, c)) }
        }
        if let dot = Theme.blankImage {
            register(marker, Cursor(size: CGSize(width: 1, height: 1), hotSpot: .zero,
                                    frameCount: 1, frameDuration: 0, images: [dot]))
        }
        refresh()
        return failed.sorted()
    }

    static var scale: Float {
        get { var s: Float = 1; CGSGetCursorScale(cid, &s); return s }
        set { CGSSetCursorScale(cid, min(max(newValue, 0.5), 16)) }
    }

    /// Wiggling the scale makes WindowServer redraw the cursor under the pointer
    /// immediately instead of on the next cursor change.
    static func refresh() {
        let s = scale
        scale = s + 0.3
        scale = s
    }
}

struct Cursor {
    var size: CGSize
    var hotSpot: CGPoint
    var frameCount: Int
    var frameDuration: CGFloat
    var images: [CGImage]
}
