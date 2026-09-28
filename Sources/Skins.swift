import Foundation

/// Skins you can download: .cape files published in public GitHub repos.
/// Listing uses the unauthenticated GitHub API (60 requests/hour), so each
/// repo's listing is cached for a day; previews and downloads come from
/// raw.githubusercontent.com and are cached by blob hash.
struct RemoteSkin: Identifiable, Codable, Hashable {
    let repo: String        // "owner/name"
    let path: String        // path of the .cape inside the repo
    let sha: String         // git blob hash; changes when the file does
    let size: Int?

    var id: String { repo + "/" + path }
    /// File name without extension; what Store.importTheme will call the theme.
    var themeID: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }

    /// Display name: drops the ".UUID" some collections append to file names.
    var name: String {
        themeID.replacingOccurrences(of: #"\.[0-9A-Fa-f]{8}-[0-9A-Fa-f-]{27}$"#, with: "", options: .regularExpression)
    }

    var rawURL: URL {
        let encoded = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        return URL(string: "https://raw.githubusercontent.com/\(repo)/HEAD/\(encoded)")!
    }
}

enum SkinCatalog {
    /// Repos known to hold .cape skins. More can be added from the panel.
    static let builtIn = [
        "Microtribute/mac-cursors",
        "GinoXiscatti/MacOS-Cursors-Collection",
        "wirenux/Bibata-Mouse-Cape",
        "jtof-dev/posy-cursor-macos",
        "Dqixol/mousecape_breeze",
        "haxybaxy/banana-cursor",
        "ryenus/obsidian.cape",
        "seaBFH/mousescape-nyan_cat",
        "NeoCat/enhanced-ibeam",
        "obatola/mousecape-hand-cursor",
        "Uyukisan/mousecape-Anya",
    ]

    /// Places to find more by hand (these aren't .cape repos, so they can't be listed).
    static let webLinks: [(title: String, url: String, note: String)] = [
        ("GitHub · .cape search", "https://github.com/search?q=path%3A*.cape&type=code", "Every .cape file on GitHub"),
        ("RW Designer cursors", "https://www.rw-designer.com/cursor-library", "Windows cursors; convert with capeify"),
        ("capeify", "https://github.com/mmemoo/capeify", "Turns Windows cursor packs into .cape"),
    ]

    static let sourcesURL = Store.root.appendingPathComponent("sources.json")
    private static let listCacheURL = Store.root.appendingPathComponent("skins-cache.json")
    static let fileCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MouseSkins/skins")

    static var extraSources: [String] {
        get { (try? JSONDecoder().decode([String].self, from: Data(contentsOf: sourcesURL))) ?? [] }
        set {
            try? FileManager.default.createDirectory(at: Store.root, withIntermediateDirectories: true)
            try? JSONEncoder().encode(newValue).write(to: sourcesURL, options: .atomic)
        }
    }

    static var sources: [String] { builtIn + extraSources.filter { !builtIn.contains($0) } }

    /// "https://github.com/owner/repo/…", "github.com/owner/repo" or "owner/repo" → "owner/repo".
    static func normalize(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "www.", "github.com/"] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
        }
        if s.hasPrefix("github.com/") { s.removeFirst("github.com/".count) }
        let parts = s.split(separator: "/").prefix(2).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return parts[0] + "/" + parts[1].replacingOccurrences(of: ".git", with: "")
    }

    // MARK: listing

    private struct Cached: Codable { var fetched: Date; var skins: [RemoteSkin] }

    private static func loadListCache() -> [String: Cached] {
        (try? JSONDecoder().decode([String: Cached].self, from: Data(contentsOf: listCacheURL))) ?? [:]
    }

    private static func saveListCache(_ c: [String: Cached]) {
        try? FileManager.default.createDirectory(at: Store.root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(c).write(to: listCacheURL, options: .atomic)
    }

    enum FetchError: LocalizedError {
        case http(String, Int), rateLimited
        var errorDescription: String? {
            switch self {
            case .http(let repo, let code): return "\(repo): GitHub answered \(code)"
            case .rateLimited: return "GitHub's hourly limit for anonymous requests is used up; cached lists still work."
            }
        }
    }

    /// Lists the .cape files in a repo (cached for a day unless forced).
    static func list(_ repo: String, force: Bool = false) async throws -> [RemoteSkin] {
        var cache = loadListCache()
        if !force, let hit = cache[repo], Date().timeIntervalSince(hit.fetched) < 86_400 { return hit.skins }

        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/git/trees/HEAD?recursive=1")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            if let stale = cache[repo] { return stale.skins }        // offline or limited: use what we had
            throw code == 403 || code == 429 ? FetchError.rateLimited : FetchError.http(repo, code)
        }
        struct Tree: Decodable { struct Item: Decodable { let path: String; let type: String; let sha: String; let size: Int? }; let tree: [Item] }
        let skins = try JSONDecoder().decode(Tree.self, from: data).tree
            .filter { $0.type == "blob" && $0.path.lowercased().hasSuffix(".cape") }
            .map { RemoteSkin(repo: repo, path: $0.path, sha: $0.sha, size: $0.size) }
        cache[repo] = Cached(fetched: Date(), skins: skins)
        saveListCache(cache)
        return skins
    }

    // MARK: files

    /// Downloads (or reuses) the .cape and returns its local cached path.
    static func file(for skin: RemoteSkin) async throws -> URL {
        let dest = fileCache.appendingPathComponent(skin.sha).appendingPathComponent(skin.themeID + ".cape")
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        let (tmp, response) = try await URLSession.shared.download(from: skin.rawURL)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw FetchError.http(skin.repo, code) }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Downloads a skin into the library; returns its theme id.
    static func install(_ skin: RemoteSkin) async throws -> String {
        try Store.importTheme(from: try await file(for: skin))
    }
}
