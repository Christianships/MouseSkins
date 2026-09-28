import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: model

/// Everything the panel shows. Themes are reloaded on demand (import, delete,
/// panel open); the applied theme and settings also follow CLI changes through
/// the "dev.mouseskins.changed" notification Store posts on every state write.
final class LibraryModel: ObservableObject {
    enum Tab: String, CaseIterable { case home = "Home", skins = "Skins", edit = "Edit", settings = "Settings" }

    struct Entry: Identifiable {
        let id: String              // "" = macOS Default
        let theme: Theme?
        let error: String?
    }

    @Published var tab: Tab = Tab(rawValue: UserDefaults.standard.string(forKey: "tab") ?? "") ?? .home {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "tab") }     // reopen where you left off
    }
    @Published var entries: [Entry] = []
    @Published var selection: String = ""
    private var didSelectInitially = false
    @Published var applied: String = ""
    @Published var problem: String?

    // settings
    @Published var scale: Double = 1
    @Published var loginEnabled = false
    @Published var leftHanded = false
    @Published var showMenuBar = true
    @Published var swing = false

    // editor: a working copy of the selected theme, saved explicitly
    @Published var draft: Theme?
    @Published var editGroup: String?
    @Published var dirty = false

    init() {
        reload()
        DistributedNotificationCenter.default().addObserver(
            forName: .init("dev.mouseskins.changed"), object: nil, queue: .main) { [weak self] _ in self?.syncState() }
    }

    var selected: Entry? { entries.first { $0.id == selection } }

    func reload() {
        var list = [Entry(id: "", theme: Store.savedDefaults, error: nil)]
        for id in Store.themeIDs() {
            do { list.append(Entry(id: id, theme: try Store.theme(id), error: nil)) }
            catch { list.append(Entry(id: id, theme: nil, error: error.localizedDescription)) }
        }
        entries = list
        syncState()
        // Open on the applied theme; afterwards keep whatever the user picked.
        if !didSelectInitially || !list.contains(where: { $0.id == selection }) { selection = applied }
        didSelectInitially = true
        if !dirty { resetDraft() }
    }

    func syncState() {
        let s = Store.state
        applied = s.theme ?? ""
        scale = Double(s.scale ?? Cursors.scale)
        leftHanded = s.leftHanded == true
        showMenuBar = s.hideMenuBar != true
        swing = s.swing == true
        loginEnabled = SMAppService.mainApp.status == .enabled
    }

    func select(_ id: String) {
        guard id != selection else { return }
        selection = id
        dirty = false
        resetDraft()
    }

    // MARK: actions

    func apply(_ id: String) {
        problem = Store.use(id.isEmpty ? nil : id)
        syncState()
    }

    func setScale(_ value: Double) { scale = value; Store.setScale(Float(value)) }

    func setLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { problem = error.localizedDescription }
        syncState()
    }

    func setLeftHanded(_ on: Bool) {
        var s = Store.state
        s.leftHanded = on ? true : nil
        Store.state = s
        if s.theme != nil { Store.applySaved() }
        syncState()
    }

    func setSwing(_ on: Bool) {
        var s = Store.state
        s.swing = on ? true : nil
        Store.state = s
        syncState()
    }

    func setShowMenuBar(_ on: Bool) {
        var s = Store.state
        s.hideMenuBar = on ? nil : true
        Store.state = s
        syncState()
    }

    func importThemes() {
        let panel = NSOpenPanel()
        panel.title = "Import cursor theme"
        panel.message = "Choose .cape files or folders containing theme.json"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
    }

    func importURLs(_ urls: [URL]) {
        var failures: [String] = [], last: String?
        for url in urls {
            do { last = try Store.importTheme(from: url) }
            catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        reload()
        if let last { select(last) }
        problem = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    /// Saves the selected theme as a .cape file anywhere.
    func export() {
        guard let theme = selected?.theme else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = theme.name + ".cape"
        panel.allowedContentTypes = [UTType(filenameExtension: "cape") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Theme.writeCape(theme.cursors, name: theme.name, author: theme.author ?? "",
                                identifier: theme.capeIdentifier, to: url)
        } catch { problem = error.localizedDescription }
    }

    func delete(_ id: String) {
        guard !id.isEmpty else { return }
        do { try Store.remove(id) } catch { problem = error.localizedDescription }
        reload()
        select(applied)
    }

    func reveal(_ id: String) {
        if let url = Store.url(for: id) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    // MARK: editing

    var editableGroups: [CursorGroup] { draft.map(CursorGroup.present(in:)) ?? [] }

    func resetDraft() {
        draft = selection.isEmpty ? nil : selected?.theme
        dirty = false
        if !editableGroups.contains(where: { $0.id == editGroup }) { editGroup = editableGroups.first?.id }
    }

    /// Changes every cursor in the current group at once.
    func editCurrent(_ change: (inout Cursor) -> Void) {
        guard var d = draft, let group = editableGroups.first(where: { $0.id == editGroup }) else { return }
        for ident in group.idents(in: d) where d.cursors[ident] != nil { change(&d.cursors[ident]!) }
        draft = d
        dirty = true
    }

    var currentCursor: Cursor? {
        guard let d = draft, let group = editableGroups.first(where: { $0.id == editGroup }) else { return nil }
        return group.idents(in: d).lazy.compactMap { d.cursors[$0] }.first
    }

    func replaceImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .tiff, .image]
        panel.message = "Choose an image for \(editGroup ?? "this cursor") (square works best; frames stacked vertically for animation)"
        guard panel.runModal() == .OK, let url = panel.url, let img = Theme.image(at: url) else { return }
        editCurrent { c in
            let frames = max(c.frameCount, 1)
            // Keep the point size; a big image just becomes the Retina copy.
            if img.height % frames != 0 || img.height / frames != img.width { c.frameCount = 1; c.frameDuration = 0 }
            c.images = [img]
        }
    }

    func saveDraft() {
        guard let d = draft else { return }
        do {
            try d.save()
            dirty = false
            if applied == d.id { Store.applySaved() }
            reload()
        } catch { problem = error.localizedDescription }
    }
}

// MARK: panel

/// A floating HUD centred on the screen the pointer is on, like Spotlight.
/// Esc or clicking elsewhere dismisses it.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
    override func resignKey() {
        super.resignKey()
        // Stay open while our own open/save panel or alert is up.
        if NSApp.modalWindow == nil && !(NSApp.keyWindow is NSOpenPanel) { close() }
    }
}

/// The panel runs in its own short-lived process (`MouseSkins --panel`, started by
/// the menu bar agent) and quits when it closes. SwiftUI's view tree, its
/// caches and every theme's decoded images add ~20 MB that a long-running
/// process never gives back, so the agent that sits in the menu bar all day
/// never loads any of it.
enum MouseSkinsPanel {
    static let size = NSSize(width: 600, height: 460)
    private static var panel: FloatingPanel?

    static func show() {
        let p = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            p.standardWindowButton(b)?.isHidden = true
        }
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        let host = NSHostingView(rootView: PanelView().environmentObject(LibraryModel()))
        host.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.topAnchor.constraint(equalTo: blur.topAnchor),
            host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        p.contentView = blur
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        panel = p

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }
}

/// Starts and stops the panel process from the menu bar agent.
enum PanelProcess {
    private static var process: Process?

    static func toggle() {
        if let p = process, p.isRunning { p.terminate(); process = nil; return }
        let p = Process()
        p.executableURL = Bundle.main.executableURL
        p.arguments = ["--panel"]
        do { try p.run(); process = p } catch { NSSound.beep() }
    }
}

// MARK: shell

struct PanelView: View {
    @EnvironmentObject var model: LibraryModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $model.tab) {
                    ForEach(LibraryModel.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                Spacer()
                toolbar
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)

            Group {
                switch model.tab {
                case .home: HomeView()
                case .skins: SkinsView()
                case .edit: EditView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()      // the hidden title bar would otherwise leave a gap on top
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { model.importURLs([url]) } }
                }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2).padding(3)
            }
        }
        .alert("MouseSkins", isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.problem ?? "")
        }
    }

    @ViewBuilder private var toolbar: some View {
        switch model.tab {
        case .home:
            IconButton("plus", "Import .cape or theme folder (or drop one here)") { model.importThemes() }
            IconButton("square.and.arrow.up", "Export as .cape") { model.export() }
                .disabled(model.selected?.theme == nil)
            IconButton("trash", "Move to Trash", tint: .red) { model.delete(model.selection) }
                .disabled(model.selection.isEmpty)
            IconButton("checkmark", "Apply", tint: .green, filled: true) { model.apply(model.selection) }
                .disabled(model.applied == model.selection || model.selected?.error != nil)
        case .skins:
            SkinsToolbar()
        case .edit:
            IconButton("arrow.uturn.backward", "Discard changes") { model.resetDraft() }
                .disabled(!model.dirty)
            IconButton("checkmark", "Save", tint: .green, filled: true) { model.saveDraft() }
                .disabled(!model.dirty)
        case .settings:
            IconButton("folder", "Open themes folder") { NSWorkspace.shared.open(Store.themesDir) }
            IconButton("arrow.counterclockwise", "Restore macOS cursors") { model.apply("") }
        }
    }
}

struct IconButton: View {
    let symbol: String, help: String
    var tint: Color? = nil
    var filled = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    init(_ symbol: String, _ help: String, tint: Color? = nil, filled: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol; self.help = help; self.tint = tint; self.filled = filled; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(filled ? Color.white : tint ?? Color.primary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(filled ? AnyShapeStyle(tint ?? .accentColor) : AnyShapeStyle(Color.primary.opacity(0.08))))
                .opacity(enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: home

struct HomeView: View {
    @EnvironmentObject var model: LibraryModel
    private let columns = [GridItem(.adaptive(minimum: 82), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.entries) { entry in
                        ThemeTile(entry: entry, selected: model.selection == entry.id,
                                  applied: model.applied == entry.id)
                            .onTapGesture(count: 2) { model.select(entry.id); model.apply(entry.id) }
                            .onTapGesture { model.select(entry.id) }
                            .contextMenu {
                                Button("Apply") { model.apply(entry.id) }
                                Button("Edit") { model.select(entry.id); model.tab = .edit }
                                    .disabled(entry.id.isEmpty)
                                if !entry.id.isEmpty {
                                    Button("Show in Finder") { model.reveal(entry.id) }
                                    Divider()
                                    Button("Move to Trash", role: .destructive) { model.delete(entry.id) }
                                }
                            }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 2)
            }
            .frame(height: 96)

            if let entry = model.selected {
                header(entry).padding(.horizontal, 16)
                if let theme = entry.theme {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(CursorGroup.present(in: theme)) { group in
                                let c = group.idents(in: theme).compactMap { theme.cursors[$0] }.first!
                                VStack(spacing: 6) {
                                    CursorPreview(cursor: c, side: 34).frame(height: 40)
                                    Text(group.name).font(.system(size: 10, weight: .medium))
                                        .lineLimit(1).truncationMode(.tail)
                                }
                                .padding(.vertical, 10).padding(.horizontal, 6)
                                .frame(maxWidth: .infinity)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
                                .help("\(group.name) · \(group.keys.count) type\(group.keys.count == 1 ? "" : "s")")
                            }
                        }
                        .padding(.horizontal, 16).padding(.bottom, 8)
                    }
                    Text("\(theme.cursors.count) cursors · double-click a theme to apply")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.bottom, 12)
                } else {
                    Text(entry.error ?? "The stock cursors aren't saved yet. MouseSkins saves them the first time it runs in a fresh login session; until then, going back to them takes a logout.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
                }
            }
        }
    }

    private func header(_ entry: LibraryModel.Entry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(entry.id.isEmpty ? "macOS Default" : entry.theme?.name ?? entry.id)
                    .font(.system(size: 17, weight: .bold)).lineLimit(1)
                if model.applied == entry.id { Badge(text: "Applied", color: .green, symbol: "checkmark.circle.fill") }
                if entry.theme?.isAnimated == true { Badge(text: "Animated", color: .yellow) }
            }
            if let author = entry.theme?.author, !author.isEmpty, !entry.id.isEmpty {
                Text("by \(author)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
    }
}

struct Badge: View {
    let text: String, color: Color
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(color == .yellow ? Color.black : Color.white)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(color))
    }
}

/// A theme in the strip: its arrow, name, and a dot when applied.
struct ThemeTile: View {
    let entry: LibraryModel.Entry
    let selected: Bool
    let applied: Bool

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let arrow = entry.theme?.cursors["com.apple.coregraphics.Arrow"] {
                    CursorPreview(cursor: arrow, side: 36)
                } else {
                    Image(systemName: entry.error == nil ? "cursorarrow" : "exclamationmark.triangle")
                        .font(.system(size: 24)).foregroundStyle(.secondary)
                }
            }
            .frame(height: 40)
            HStack(spacing: 4) {
                if applied { Circle().fill(.green).frame(width: 6, height: 6) }
                Text(entry.id.isEmpty ? "macOS Default" : entry.theme?.name ?? entry.id)
                    .font(.system(size: 10, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
            }
        }
        .frame(width: 84, height: 84)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(selected ? 0.12 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(selected ? Color.green.opacity(0.8) : .clear, lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .help(entry.error ?? entry.theme?.author ?? "")
    }
}

// MARK: skins

@MainActor
final class SkinsModel: ObservableObject {
    static let shared = SkinsModel()    // the panel process is short-lived; one catalog per run

    @Published var skins: [RemoteSkin] = []
    @Published var loading = false
    @Published var loaded = false
    @Published var errors: [String] = []
    @Published var query = ""
    @Published var source = ""          // "" = all sources
    @Published var installing: Set<String> = []
    @Published var previews: [String: [Cursor]] = [:]
    private var previewing: Set<String> = []

    var filtered: [RemoteSkin] {
        skins.filter { skin in
            (source.isEmpty || skin.repo == source)
                && (query.isEmpty || skin.name.localizedCaseInsensitiveContains(query)
                    || skin.repo.localizedCaseInsensitiveContains(query))
        }
    }

    func load(force: Bool = false) async {
        guard !loading else { return }
        loading = true
        errors = []
        var all: [RemoteSkin] = [], problems: [String] = []
        await withTaskGroup(of: Result<[RemoteSkin], Error>.self) { group in
            for repo in SkinCatalog.sources {
                group.addTask { do { return .success(try await SkinCatalog.list(repo, force: force)) } catch { return .failure(error) } }
            }
            for await r in group {
                switch r {
                case .success(let list): all += list
                case .failure(let e): problems.append(e.localizedDescription)
                }
            }
        }
        // Same file in two repos (forks, collections) → keep one.
        var seen = Set<String>()
        skins = all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .filter { seen.insert($0.sha).inserted && seen.insert($0.name.lowercased()).inserted }
        errors = Array(Set(problems)).sorted()
        loading = false
        loaded = true
    }

    /// Downloads the cape (cached by hash) and keeps a few cursors to show.
    func preview(_ skin: RemoteSkin) async {
        guard previews[skin.id] == nil, previewing.insert(skin.id).inserted else { return }
        defer { previewing.remove(skin.id) }
        guard let url = try? await SkinCatalog.file(for: skin), let theme = try? Theme.loadCape(url) else {
            previews[skin.id] = []
            return
        }
        previews[skin.id] = ["arrow", "pointing", "ibeam", "wait"]
            .compactMap { Cursors.names[$0].flatMap { theme.cursors[$0] } }
    }

    func install(_ skin: RemoteSkin, library: LibraryModel, apply: Bool) async {
        installing.insert(skin.id)
        defer { installing.remove(skin.id) }
        do {
            let id = try await SkinCatalog.install(skin)
            library.reload()
            if apply { library.apply(id) }
        } catch {
            library.problem = "\(skin.name): \(error.localizedDescription)"
        }
    }

    func addSource(_ input: String) async -> String? {
        guard let repo = SkinCatalog.normalize(input) else { return "Use owner/repo or a github.com link" }
        if SkinCatalog.sources.contains(repo) { return "\(repo) is already a source" }
        do {
            let found = try await SkinCatalog.list(repo, force: true)
            if found.isEmpty { return "No .cape files in \(repo)" }
        } catch { return error.localizedDescription }
        SkinCatalog.extraSources += [repo]
        await load()
        source = repo
        return nil
    }

    func removeSource(_ repo: String) {
        SkinCatalog.extraSources.removeAll { $0 == repo }
        if source == repo { source = "" }
        skins.removeAll { $0.repo == repo }
    }
}

struct SkinsToolbar: View {
    @ObservedObject private var skins = SkinsModel.shared
    @State private var adding = false
    @State private var input = ""
    @State private var addError: String?

    var body: some View {
        IconButton("plus", "Add a GitHub repo as a source") { adding = true }
            .popover(isPresented: $adding, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add source").font(.headline)
                    Text("A GitHub repo with .cape files").font(.caption).foregroundStyle(.secondary)
                    TextField("owner/repo or github.com link", text: $input).frame(width: 260)
                        .onSubmit(submit)
                    if let addError { Text(addError).font(.caption).foregroundStyle(.red) }
                    HStack { Spacer(); Button("Add", action: submit).keyboardShortcut(.defaultAction) }
                }
                .padding(14)
            }
        Menu {
            ForEach(SkinCatalog.webLinks, id: \.url) { link in
                Button("\(link.title) — \(link.note)") { NSWorkspace.shared.open(URL(string: link.url)!) }
            }
        } label: { Image(systemName: "globe") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 30)
            .help("Find more skins on the web")
        IconButton("arrow.clockwise", "Refresh from GitHub") { Task { await skins.load(force: true) } }
            .disabled(skins.loading)
    }

    private func submit() {
        let text = input
        Task {
            addError = await skins.addSource(text)
            if addError == nil { adding = false; input = "" }
        }
    }
}

struct SkinsView: View {
    @EnvironmentObject var library: LibraryModel
    @ObservedObject private var skins = SkinsModel.shared
    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 10)]

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search skins", text: $skins.query).textFieldStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
                Picker("", selection: $skins.source) {
                    Text("All sources").tag("")
                    ForEach(SkinCatalog.sources, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 190)
            }
            .padding(.horizontal, 16)

            if skins.loading && skins.skins.isEmpty {
                ProgressView("Looking on GitHub…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(skins.filtered) { skin in card(skin) }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 10)
                    if skins.loaded && skins.filtered.isEmpty {
                        Text(skins.query.isEmpty ? "Nothing here yet." : "No skins match “\(skins.query)”.")
                            .foregroundStyle(.secondary).padding(30)
                    }
                }
            }

            HStack(spacing: 6) {
                Text("\(skins.filtered.count) skins from \(skins.source.isEmpty ? "\(SkinCatalog.sources.count) GitHub repos" : skins.source)")
                if !skins.source.isEmpty {
                    Button { NSWorkspace.shared.open(URL(string: "https://github.com/\(skins.source)")!) } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderless).help("Open on GitHub")
                    if SkinCatalog.extraSources.contains(skins.source) {
                        Button("Remove source") { skins.removeSource(skins.source) }.buttonStyle(.link)
                    }
                }
                Spacer()
                if let e = skins.errors.first {
                    Label(e, systemImage: "exclamationmark.triangle").lineLimit(1).foregroundStyle(.orange)
                        .help(skins.errors.joined(separator: "\n"))
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
        .task { if !skins.loaded { await skins.load() } }
    }

    private func card(_ skin: RemoteSkin) -> some View {
        let installed = library.entries.contains { $0.id == skin.themeID }
        let applied = library.applied == skin.themeID
        let busy = skins.installing.contains(skin.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let cursors = skins.previews[skin.id] {
                    if cursors.isEmpty {
                        Image(systemName: "questionmark.square.dashed").foregroundStyle(.secondary).frame(height: 28)
                    }
                    ForEach(Array(cursors.enumerated()), id: \.offset) { CursorPreview(cursor: $0.element, side: 28) }
                } else {
                    ProgressView().controlSize(.small).frame(height: 28)
                }
                Spacer(minLength: 0)
            }
            .task { await skins.preview(skin) }
            VStack(alignment: .leading, spacing: 1) {
                Text(skin.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(skin.repo.components(separatedBy: "/").first ?? skin.repo)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack {
                if applied {
                    Label("Applied", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                } else if installed {
                    Button("Apply") { library.apply(skin.themeID) }.controlSize(.small)
                } else {
                    Button(busy ? "Getting…" : "Get") { Task { await skins.install(skin, library: library, apply: false) } }
                        .controlSize(.small).disabled(busy)
                    Button("Get & Apply") { Task { await skins.install(skin, library: library, apply: true) } }
                        .controlSize(.small).disabled(busy)
                }
                Spacer()
                if let size = skin.size {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(applied ? Color.green.opacity(0.7) : .clear, lineWidth: 1.5))
        .contextMenu {
            Button("Open on GitHub") {
                NSWorkspace.shared.open(URL(string: "https://github.com/\(skin.repo)/blob/HEAD/\(skin.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? skin.path)")!)
            }
        }
    }
}

// MARK: edit

struct EditView: View {
    @EnvironmentObject var model: LibraryModel
    @State private var showHotspot = true

    var body: some View {
        if model.draft == nil {
            Text(model.selection.isEmpty ? "The macOS cursors can't be edited. Pick a theme on Home."
                                         : "This theme couldn't be loaded.")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                groupList.frame(width: 190)
                Divider().opacity(0.4)
                if let c = model.currentCursor { editor(c) } else { Spacer() }
            }
        }
    }

    private var groupList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(model.editableGroups) { group in
                    let theme = model.draft!
                    let c = group.idents(in: theme).compactMap { theme.cursors[$0] }.first!
                    HStack(spacing: 10) {
                        CursorPreview(cursor: c, side: 22).frame(width: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            Text("\(group.keys.count) type\(group.keys.count == 1 ? "" : "s")")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(model.editGroup == group.id ? 0.12 : 0)))
                    .contentShape(Rectangle())
                    .onTapGesture { model.editGroup = group.id }
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 12)
        }
    }

    private func editor(_ c: Cursor) -> some View {
        let box: CGFloat = 150
        let k = box / max(c.size.width, c.size.height, 1)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Preview: drag anywhere to move the hotspot.
                ZStack(alignment: .topLeading) {
                    CursorPreview(cursor: c, side: box, pixelated: true)
                    if showHotspot {
                        Circle().fill(.red).overlay(Circle().stroke(.white, lineWidth: 1.5))
                            .frame(width: 10, height: 10)
                            .offset(x: c.hotSpot.x * k - 5, y: c.hotSpot.y * k - 5)
                    }
                }
                .frame(width: box, height: box)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    model.editCurrent { cur in
                        cur.hotSpot = CGPoint(x: min(max((g.location.x / k).rounded(), 0), cur.size.width - 1),
                                              y: min(max((g.location.y / k).rounded(), 0), cur.size.height - 1))
                    }
                })
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.2)))

                section("Hotspot") {
                    HStack {
                        Toggle("Show", isOn: $showHotspot).toggleStyle(.switch).controlSize(.mini)
                        Spacer()
                        Button("Center") {
                            model.editCurrent { $0.hotSpot = CGPoint(x: ($0.size.width / 2).rounded(),
                                                                     y: ($0.size.height / 2).rounded()) }
                        }
                        .controlSize(.small)
                    }
                    axis("X", c.hotSpot.x, c.size.width) { v in model.editCurrent { $0.hotSpot.x = v } }
                    axis("Y", c.hotSpot.y, c.size.height) { v in model.editCurrent { $0.hotSpot.y = v } }
                    Text("Tip: drag in the preview to move the hotspot")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if c.frameCount > 1 {
                    section("Animation") {
                        HStack {
                            Text("Frame time").font(.callout)
                            Slider(value: Binding(get: { Double(c.frameDuration) },
                                                  set: { v in model.editCurrent { $0.frameDuration = v } }),
                                   in: 0.02...0.5)
                            Text(String(format: "%.0f ms", c.frameDuration * 1000))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52)
                        }
                        Text("\(c.frameCount) frames").font(.caption).foregroundStyle(.secondary)
                    }
                }

                section("Image") {
                    HStack {
                        Text("\(Int(c.size.width))×\(Int(c.size.height)) pt · \(c.images.count) resolution\(c.images.count == 1 ? "" : "s")")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Replace…") { model.replaceImage() }.controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 14)
        }
    }

    private func axis(_ label: String, _ value: CGFloat, _ max: CGFloat, set: @escaping (CGFloat) -> Void) -> some View {
        HStack {
            Text(label).font(.callout.monospaced()).frame(width: 14)
            Slider(value: Binding(get: { Double(value) }, set: { set(CGFloat($0.rounded())) }),
                   in: 0...Double(Swift.max(max - 1, 1)))
            Text(String(format: "%.0f", value)).font(.caption.monospacedDigit())
                .foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8, content: content)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
        }
    }
}

// MARK: settings

struct SettingsView: View {
    @EnvironmentObject var model: LibraryModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                group("Startup") {
                    row("Apply at login", "Opens MouseSkins at login and re-applies your theme") {
                        Toggle("", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                    }
                    Divider().opacity(0.4)
                    row("Show menu bar icon", "When hidden, open MouseSkins again to get this panel") {
                        Toggle("", isOn: Binding(get: { model.showMenuBar }, set: { model.setShowMenuBar($0) }))
                    }
                }
                group("Cursor scale") {
                    HStack {
                        Text("1×").font(.caption).foregroundStyle(.secondary)
                        Slider(value: Binding(get: { model.scale }, set: { model.setScale($0) }), in: 1...4, step: 0.25)
                        Text("4×").font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "%.2g×", model.scale)).monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                    Text("Same size WindowServer uses for the Accessibility pointer size.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                group("Cursor direction") {
                    row("Hand", "Left-hand mode mirrors pointer cursors horizontally") {
                        Picker("", selection: Binding(get: { model.leftHanded }, set: { model.setLeftHanded($0) })) {
                            Text("Right").tag(false)
                            Text("Left").tag(true)
                        }
                        .pickerStyle(.segmented).frame(width: 130)
                    }
                    Divider().opacity(0.4)
                    row("Swing on click", "Normal and Link Select swing like a sword on every click") {
                        Toggle("", isOn: Binding(get: { model.swing }, set: { model.setSwing($0) }))
                    }
                }
            }
            .toggleStyle(.switch).labelsHidden()
            .padding(.horizontal, 16).padding(.bottom, 16)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10, content: content)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
        }
    }

    private func row<Control: View>(_ title: String, _ detail: String, @ViewBuilder _ control: () -> Control) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            control()
        }
    }
}

// MARK: preview

/// Draws a cursor at a fixed box size, playing its frames if it's animated.
struct CursorPreview: View {
    let cursor: Cursor
    let side: CGFloat
    var pixelated = false

    var body: some View {
        if cursor.frameCount > 1, cursor.frameDuration > 0 {
            TimelineView(.periodic(from: .now, by: cursor.frameDuration)) { ctx in
                let i = Int(ctx.date.timeIntervalSinceReferenceDate / cursor.frameDuration) % cursor.frameCount
                frame(i)
            }
        } else {
            frame(0)
        }
    }

    @ViewBuilder private func frame(_ index: Int) -> some View {
        // Largest representation, cropped to one frame of the vertical strip.
        if let sheet = cursor.images.max(by: { $0.width < $1.width }),
           case let h = sheet.height / max(cursor.frameCount, 1),
           let cg = sheet.cropping(to: CGRect(x: 0, y: index * h, width: sheet.width, height: h)) {
            Image(decorative: cg, scale: 1)
                .resizable().interpolation(pixelated ? .none : .high)
                .aspectRatio(contentMode: .fit)
                .frame(width: side, height: side)
        } else {
            Color.clear.frame(width: side, height: side)
        }
    }
}
