import AppKit
import ImageIO

/// A cursor theme, loaded from either a Mousecape `.cape` file or an msig
/// theme folder (a `theme.json` next to PNGs).
struct Theme {
    var id: String          // file or folder name without extension; what `msig apply` takes
    var name: String
    var author: String?
    var cursors: [String: Cursor]   // keyed by full identifier (com.apple.…)

    enum LoadError: LocalizedError {
        case unreadable(String), badCursor(String, String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let why): return why
            case .badCursor(let key, let why): return "\(key): \(why)"
            }
        }
    }

    static func load(_ url: URL) throws -> Theme {
        url.pathExtension == "cape" ? try loadCape(url) : try loadFolder(url)
    }

    // MARK: .cape (Mousecape plist)

    static func loadCape(_ url: URL) throws -> Theme {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let raw = plist["Cursors"] as? [String: [String: Any]]
        else { throw LoadError.unreadable("\(url.lastPathComponent) is not a valid .cape file") }

        var cursors: [String: Cursor] = [:]
        for (ident, c) in raw {
            let reps = (c["Representations"] as? [Data] ?? []).compactMap(cgImage)
            guard !reps.isEmpty else { throw LoadError.badCursor(ident, "no readable images") }
            cursors[ident] = Cursor(
                size: CGSize(width: num(c["PointsWide"]), height: num(c["PointsHigh"])),
                hotSpot: CGPoint(x: num(c["HotSpotX"]), y: num(c["HotSpotY"])),
                frameCount: Int(num(c["FrameCount"], 1)),
                frameDuration: num(c["FrameDuration"]),
                images: reps)
        }
        return Theme(id: url.deletingPathExtension().lastPathComponent,
                     name: plist["CapeName"] as? String ?? url.deletingPathExtension().lastPathComponent,
                     author: plist["Author"] as? String,
                     cursors: cursors)
    }

    // MARK: folder (theme.json + PNGs)

    struct Manifest: Decodable {
        var name: String?
        var author: String?
        var cursors: [String: Entry]
        struct Entry: Decodable {
            var image: String?          // defaults to "<key>.png"; "<name>@2x.png" is picked up too
            var hotspot: [Double]?      // [x, y] in points, from the top-left
            var size: [Double]?         // [w, h] in points; defaults to the 1x frame size
            var frames: Int?            // animated: frames stacked top to bottom
            var duration: Double?       // seconds per frame
        }
    }

    static func loadFolder(_ dir: URL) throws -> Theme {
        let manifestURL = dir.appendingPathComponent("theme.json")
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL)) }
        catch { throw LoadError.unreadable("\(dir.lastPathComponent)/theme.json: \(error.localizedDescription)") }

        var cursors: [String: Cursor] = [:]
        for (key, e) in manifest.cursors {
            guard let ident = identifier(for: key) else {
                throw LoadError.badCursor(key, "unknown cursor name (see `msig names`)")
            }
            let base = (e.image ?? "\(key).png") as NSString
            let file1x = dir.appendingPathComponent(base as String)
            let file2x = dir.appendingPathComponent("\(base.deletingPathExtension)@2x.\(base.pathExtension.isEmpty ? "png" : base.pathExtension)")
            let img1x = image(at: file1x), img2x = image(at: file2x)
            guard img1x != nil || img2x != nil else {
                throw LoadError.badCursor(key, "missing \(file1x.lastPathComponent) (or @2x)")
            }
            let frames = max(e.frames ?? 1, 1)
            let size: CGSize
            if let s = e.size, s.count == 2 {
                size = CGSize(width: s[0], height: s[1])
            } else if let i = img1x {
                size = CGSize(width: i.width, height: i.height / frames)
            } else {
                size = CGSize(width: img2x!.width / 2, height: img2x!.height / frames / 2)
            }
            let hot = e.hotspot ?? [0, 0]
            cursors[ident] = Cursor(size: size,
                                    hotSpot: CGPoint(x: hot.first ?? 0, y: hot.count > 1 ? hot[1] : 0),
                                    frameCount: frames,
                                    frameDuration: e.duration ?? (frames > 1 ? 0.1 : 0),
                                    images: [img1x, img2x].compactMap { $0 })
        }
        return Theme(id: dir.lastPathComponent, name: manifest.name ?? dir.lastPathComponent,
                     author: manifest.author, cursors: cursors)
    }

    /// Accepts a full identifier or a friendly name ("pointing", "Resize N-S").
    static func identifier(for key: String) -> String? {
        if key.hasPrefix("com.apple.") { return key }
        let slug = key.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
        return Cursors.names[slug]
    }

    /// Writes cursors as a Mousecape-compatible .cape (used for the saved defaults,
    /// and loadable anywhere a .cape is).
    static func writeCape(_ cursors: [String: Cursor], name: String, to url: URL) throws {
        var dict: [String: Any] = [:]
        for (ident, c) in cursors {
            dict[ident] = [
                "FrameCount": c.frameCount, "FrameDuration": c.frameDuration,
                "HotSpotX": c.hotSpot.x, "HotSpotY": c.hotSpot.y,
                "PointsWide": c.size.width, "PointsHigh": c.size.height,
                "Representations": c.images.compactMap(png),
            ]
        }
        let plist: [String: Any] = [
            "CapeName": name, "CapeVersion": 1.0, "Author": "macOS", "Cloud": false, "HiDPI": true,
            "Identifier": "dev.msig." + name.lowercased().replacingOccurrences(of: " ", with: "-"),
            "MinimumVersion": 2.0, "Version": 2.0, "Cursors": dict,
        ]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url, options: .atomic)
    }

    static let blankImage: CGImage? = CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )?.makeImage()

    // MARK: helpers

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    private static func num(_ v: Any?, _ fallback: Double = 0) -> Double {
        (v as? NSNumber)?.doubleValue ?? fallback
    }

    private static func image(at url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return cgImage(data)
    }

    /// Decodes and redraws into sRGB RGBA; WindowServer mis-renders cursors
    /// in other colour spaces (Mousecape retags for the same reason).
    private static func cgImage(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()
    }
}

/// Themes live in ~/Library/Application Support/msig/themes; the applied theme
/// and cursor size persist in state.json so login/wake can re-apply them.
enum Store {
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("msig")
    static let themesDir = root.appendingPathComponent("themes")
    static let stateURL = root.appendingPathComponent("state.json")
    static let defaultsURL = root.appendingPathComponent("macos-default.cape")

    struct State: Codable {
        var theme: String?      // theme id; nil = macOS default
        var scale: Float?       // nil = leave the system pointer size alone
    }

    static var state: State {
        get { (try? JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))) ?? State() }
        set {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(newValue).write(to: stateURL, options: .atomic)
            DistributedNotificationCenter.default().postNotificationName(
                .init("dev.msig.changed"), object: nil, deliverImmediately: true)
        }
    }

    /// Theme ids, sorted. A folder counts only if it has a theme.json.
    static func themeIDs() -> [String] {
        try? FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: themesDir, includingPropertiesForKeys: nil)) ?? []
        return items.compactMap { url -> String? in
            if url.pathExtension == "cape" { return url.deletingPathExtension().lastPathComponent }
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("theme.json").path) {
                return url.lastPathComponent
            }
            return nil
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func url(for id: String) -> URL? {
        let cape = themesDir.appendingPathComponent(id + ".cape")
        if FileManager.default.fileExists(atPath: cape.path) { return cape }
        let dir = themesDir.appendingPathComponent(id)
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("theme.json").path) { return dir }
        return nil
    }

    static func theme(_ id: String) throws -> Theme {
        guard let url = url(for: id) else { throw Theme.LoadError.unreadable("no theme named \"\(id)\"") }
        return try Theme.load(url)
    }

    /// Copies a .cape file or theme folder into the themes dir; returns its id.
    static func importTheme(from src: URL) throws -> String {
        _ = try Theme.load(src)     // refuse anything that won't apply
        try FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)
        let dest = themesDir.appendingPathComponent(src.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.copyItem(at: src, to: dest)
        return src.pathExtension == "cape" ? src.deletingPathExtension().lastPathComponent : src.lastPathComponent
    }

    /// Applies whatever state.json says. Used at launch, wake and display changes.
    @discardableResult
    static func applySaved() -> String? {
        let s = state
        var problem: String?
        if let id = s.theme {
            do {
                let failed = Cursors.apply(try theme(id))
                if !failed.isEmpty { problem = "couldn't register: " + failed.joined(separator: ", ") }
            } catch { problem = error.localizedDescription }
        }
        if let scale = s.scale { Cursors.scale = scale }
        return problem
    }
}
