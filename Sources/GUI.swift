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

// MARK: panel

/// A small HUD that floats in the middle of the screen the pointer is on,
/// like Spotlight. Esc or clicking elsewhere dismisses it.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
    override func resignKey() {
        super.resignKey()
        // Stay open while our own open panel or alert is up.
        if NSApp.modalWindow == nil { close() }
    }
}

enum MsigPanel {
    private static var panel: FloatingPanel?
    private static let model = LibraryModel()
    static let size = NSSize(width: 440, height: 340)

    static func show() {
        if panel == nil {
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
            let host = NSHostingView(rootView: PanelView().environmentObject(model))
            host.translatesAutoresizingMaskIntoConstraints = false
            blur.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
                host.topAnchor.constraint(equalTo: blur.topAnchor),
                host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            ])
            p.contentView = blur
            panel = p
        }
        guard let panel else { return }
        if panel.isVisible { panel.close(); return }    // menu item / reopen toggles it
        model.reload()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2,
                                  width: size.width, height: size.height), display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}

// MARK: views

struct PanelView: View {
    @EnvironmentObject var model: LibraryModel
    @State private var dropTargeted = false
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "cursorarrow.rays")
                Text("msig").font(.headline)
                Spacer()
                Button { NSWorkspace.shared.open(Store.themesDir) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Open themes folder")
                Button { model.importThemes() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("Import .cape or theme folder (or drop one here)")
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(model.entries) { entry in
                        ThemeTile(entry: entry, applied: model.applied == entry.id) { model.apply(entry.id) }
                            .contextMenu {
                                if !entry.id.isEmpty {
                                    Button("Show in Finder") { model.reveal(entry.id) }
                                    Button("Move to Trash", role: .destructive) { model.delete(entry.id) }
                                }
                            }
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 10)
            }

            Divider().opacity(0.5)
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.left.and.arrow.down.right").foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.scale }, set: { model.setScale($0) }), in: 1...4, step: 0.25)
                Text(model.scale == 1 ? "1×" : String(format: "%.2g×", model.scale))
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                Toggle("Login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                    .toggleStyle(.switch).controlSize(.mini)
                    .help("Open msig at login and re-apply your theme")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
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
        .alert("msig", isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.problem ?? "")
        }
    }
}

/// One theme: name plus a strip of its most-seen cursors. Click to apply.
struct ThemeTile: View {
    let entry: LibraryModel.Entry
    let applied: Bool
    let apply: () -> Void
    @State private var hovering = false

    private static let showcase = ["arrow", "ibeam", "pointing", "wait"].compactMap { Cursors.names[$0] }

    var body: some View {
        Button(action: apply) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(entry.id.isEmpty ? "macOS Default" : entry.theme?.name ?? entry.id)
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if applied { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                    if entry.error != nil { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
                HStack(spacing: 6) {
                    if let theme = entry.theme {
                        ForEach(Self.showcase.filter { theme.cursors[$0] != nil }, id: \.self) { ident in
                            CursorPreview(cursor: theme.cursors[ident]!, side: 28)
                        }
                    } else {
                        Image(systemName: "cursorarrow").font(.system(size: 20)).frame(height: 28)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(applied ? 0.12 : hovering ? 0.08 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(applied ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(entry.error ?? (entry.theme?.author ?? ""))
        .disabled(entry.error != nil)
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
