import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: model

/// Everything the window shows. Themes are reloaded on demand (import, delete,
/// window open); the applied theme and size also follow CLI changes through
/// the "dev.msig.changed" notification Store posts on every state write.
final class LibraryModel: ObservableObject {
    struct Entry: Identifiable {
        let id: String              // "" = macOS Default
        let theme: Theme?
        let error: String?
    }

    @Published var entries: [Entry] = []
    @Published var selection: String?
    @Published var applied: String = ""
    @Published var scale: Double = 1
    @Published var loginEnabled = false
    @Published var problem: String?

    init() {
        reload()
        DistributedNotificationCenter.default().addObserver(
            forName: .init("dev.msig.changed"), object: nil, queue: .main) { [weak self] _ in self?.syncState() }
    }

    func reload() {
        var list = [Entry(id: "", theme: Store.savedDefaults, error: nil)]
        for id in Store.themeIDs() {
            do { list.append(Entry(id: id, theme: try Store.theme(id), error: nil)) }
            catch { list.append(Entry(id: id, theme: nil, error: error.localizedDescription)) }
        }
        entries = list
        syncState()
        if selection == nil || !list.contains(where: { $0.id == selection }) { selection = applied }
    }

    func syncState() {
        let s = Store.state
        applied = s.theme ?? ""
        scale = Double(s.scale ?? Cursors.scale)
        loginEnabled = SMAppService.mainApp.status == .enabled
    }

    func apply(_ id: String) {
        problem = Store.use(id.isEmpty ? nil : id)
        syncState()
    }

    func setScale(_ value: Double) {
        scale = value
        Store.setScale(Float(value))
    }

    func setLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { problem = error.localizedDescription }
        syncState()
    }

    func importThemes() {
        let panel = NSOpenPanel()
        panel.title = "Import cursor theme"
        panel.message = "Choose Mousecape .cape files or folders containing theme.json"
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
        if let last { selection = last }
        problem = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    func delete(_ id: String) {
        do { try Store.remove(id) } catch { problem = error.localizedDescription }
        reload()
    }

    func reveal(_ id: String) {
        if let url = Store.url(for: id) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}

// MARK: window

enum MainWindow {
    private static var window: NSWindow?
    private static let model = LibraryModel()

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "msig"
            w.minSize = NSSize(width: 640, height: 420)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: LibraryView().environmentObject(model))
            w.center()
            w.setFrameAutosaveName("msig.main")
            // In the Dock and ⌘-Tab only while the window is open.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                NSApp.setActivationPolicy(.accessory)
            }
            window = w
        }
        model.reload()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: views

struct LibraryView: View {
    @EnvironmentObject var model: LibraryModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 240)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
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
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 3).padding(4)
            }
        }
        .alert("msig", isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.problem ?? "")
        }
    }

    private var sidebar: some View {
        List(selection: $model.selection) {
            Section("Themes") {
                ForEach(model.entries) { entry in
                    ThemeRow(entry: entry, applied: model.applied == entry.id)
                        .tag(entry.id as String?)
                        .contextMenu {
                            Button("Apply") { model.apply(entry.id) }
                            if !entry.id.isEmpty {
                                Button("Show in Finder") { model.reveal(entry.id) }
                                Divider()
                                Button("Move to Trash", role: .destructive) { model.delete(entry.id) }
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder private var detail: some View {
        if let entry = model.entries.first(where: { $0.id == model.selection }) {
            ThemeDetail(entry: entry, applied: model.applied == entry.id) { model.apply(entry.id) }
        } else {
            Text("Select a theme").foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Image(systemName: "cursorarrow").foregroundStyle(.secondary)
            Slider(value: Binding(get: { model.scale }, set: { model.setScale($0) }), in: 1...4, step: 0.25)
                .frame(width: 180)
            Text(model.scale == 1 ? "Normal" : String(format: "%.2g×", model.scale))
                .monospacedDigit().frame(width: 52, alignment: .leading)
            Spacer()
            Toggle("Open at login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                .toggleStyle(.checkbox)
            Button { NSWorkspace.shared.open(Store.themesDir) } label: { Image(systemName: "folder") }
                .help("Open themes folder")
            Button("Import…") { model.importThemes() }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

struct ThemeRow: View {
    let entry: LibraryModel.Entry
    let applied: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let arrow = entry.theme?.cursors["com.apple.coregraphics.Arrow"] {
                    CursorPreview(cursor: arrow, side: 26)
                } else {
                    Image(systemName: entry.error == nil ? "cursorarrow" : "exclamationmark.triangle")
                        .font(.system(size: 16)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.id.isEmpty ? "macOS Default" : entry.theme?.name ?? entry.id).lineLimit(1)
                if let author = entry.theme?.author, !entry.id.isEmpty {
                    Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if applied {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ThemeDetail: View {
    let entry: LibraryModel.Entry
    let applied: Bool
    let apply: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.id.isEmpty ? "macOS Default" : entry.theme?.name ?? entry.id)
                        .font(.title2.weight(.semibold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if applied {
                    Label("Applied", systemImage: "checkmark").foregroundStyle(.secondary)
                } else {
                    Button("Apply", action: apply).keyboardShortcut(.defaultAction).controlSize(.large)
                        .disabled(entry.error != nil)
                }
            }
            .padding(20)
            Divider()
            content
        }
    }

    private var subtitle: String {
        if let error = entry.error { return error }
        if entry.id.isEmpty, entry.theme == nil { return "The built-in cursors" }
        let n = entry.theme?.cursors.count ?? 0
        return [entry.theme?.author, "\(n) cursor\(n == 1 ? "" : "s")"].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private var content: some View {
        if let theme = entry.theme {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(theme.cursors.keys.sorted(by: Cursors.sortOrder), id: \.self) { ident in
                        VStack(spacing: 6) {
                            CursorPreview(cursor: theme.cursors[ident]!, side: 44)
                                .frame(maxWidth: .infinity).frame(height: 64)
                                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
                            Text(Cursors.displayName(ident)).font(.caption).lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                        .help(ident)
                    }
                }
                .padding(20)
            }
        } else if entry.id.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "cursorarrow").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("The stock cursors aren't saved yet. msig saves them the first time it runs in a fresh login session; until then, going back to them takes a logout.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 340)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Spacer()
        }
    }
}

/// Draws a cursor at a fixed box size, playing its frames if it's animated.
struct CursorPreview: View {
    let cursor: Cursor
    let side: CGFloat

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
                .resizable().interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: side, height: side)
        } else {
            Color.clear.frame(width: side, height: side)
        }
    }
}
