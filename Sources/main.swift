import AppKit
import ServiceManagement

// One binary, two faces: with arguments it's the `msig` CLI, without it's the
// menu bar app. (`-psn_…` is what old launch paths append; ignore it.)
let cliArgs = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") && $0 != "--background" }
if !cliArgs.isEmpty { exit(CLI.run(Array(cliArgs))) }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var pendingReapply: DispatchWorkItem?

    private static let sizes: [Float] = [1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "msig")
        menu.delegate = self
        statusItem.menu = menu

        // Login is the one moment the stock cursors are guaranteed untouched.
        Cursors.captureDefaultsIfClean()
        Store.applySaved()

        // WindowServer drops registered cursors on some of these (display
        // reconfig, fast user switching), so re-apply after each one settles.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.screensDidWakeNotification] {
            ws.addObserver(self, selector: #selector(scheduleReapply), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleReapply),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func scheduleReapply() {
        pendingReapply?.cancel()
        let work = DispatchWorkItem { Store.applySaved() }
        pendingReapply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    // MARK: menu (rebuilt on every open so new themes and CLI changes show up)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = Store.state

        let header = NSMenuItem(title: "msig", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let def = item("macOS Default", #selector(resetCursors))
        def.state = state.theme == nil ? .on : .off
        menu.addItem(def)

        let ids = Store.themeIDs()
        for id in ids {
            let i = item(id, #selector(applyTheme(_:)))
            i.representedObject = id
            i.state = state.theme == id ? .on : .off
            menu.addItem(i)
        }
        if ids.isEmpty {
            let none = NSMenuItem(title: "No themes — Import one below", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }

        menu.addItem(.separator())
        let sizeItem = NSMenuItem(title: "Cursor Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        let current = state.scale ?? 1
        for s in Self.sizes {
            let i = item(s == 1 ? "Normal" : String(format: "%g×", s), #selector(setSize(_:)))
            i.representedObject = s
            i.state = abs(current - s) < 0.01 ? .on : .off
            sizeMenu.addItem(i)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        menu.addItem(.separator())
        menu.addItem(item("Import .cape or Theme Folder…", #selector(importTheme)))
        menu.addItem(item("Open Themes Folder", #selector(openFolder)))

        menu.addItem(.separator())
        let login = item("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Quit msig", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    // MARK: actions

    @objc private func applyTheme(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var s = Store.state
        s.theme = id
        Store.state = s
        if let problem = Store.applySaved() { alert("Couldn't apply \(id)", problem) }
    }

    @objc private func resetCursors() {
        Cursors.reset()
        var s = Store.state
        s.theme = nil
        Store.state = s
    }

    @objc private func setSize(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Float else { return }
        Cursors.scale = v
        var s = Store.state
        s.scale = v == 1 ? nil : v      // Normal = stop managing the size
        Store.state = s
    }

    @objc private func importTheme() {
        let panel = NSOpenPanel()
        panel.title = "Import cursor theme"
        panel.message = "Choose a Mousecape .cape file or a folder containing theme.json"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        var failures: [String] = []
        for url in panel.urls {
            do { _ = try Store.importTheme(from: url) }
            catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        if !failures.isEmpty { alert("Some themes weren't imported", failures.joined(separator: "\n")) }
    }

    @objc private func openFolder() {
        _ = Store.themeIDs()    // creates the folder on first use
        NSWorkspace.shared.open(Store.themesDir)
    }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            alert("Couldn't change Open at Login", error.localizedDescription)
        }
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
