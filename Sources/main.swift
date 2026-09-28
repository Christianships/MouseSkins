import AppKit
import ServiceManagement

// One binary, three faces: with arguments it's the `mouseskins` CLI; with --panel
// it's the floating panel (its own process, see PanelProcess); otherwise it's
// the menu bar agent. (`-psn_…` is what old launch paths append; ignore it.)
let args = CommandLine.arguments
if args.contains("--panel") {
    // `--tab Skins` opens on a given tab (handy for scripts and screenshots).
    if let i = args.firstIndex(of: "--tab"), i + 1 < args.count {
        UserDefaults.standard.set(args[i + 1], forKey: "tab")
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    DispatchQueue.main.async { MouseSkinsPanel.show() }
    app.run()
    exit(0)
}

let cliArgs = args.dropFirst().filter { !$0.hasPrefix("-psn_") && $0 != "--background" }
let launchedInBackground = args.contains("--background")
if !cliArgs.isEmpty { exit(CLI.run(Array(cliArgs))) }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var pendingReapply: DispatchWorkItem?

    private static let sizes: [Float] = [1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "MouseSkins")
        menu.delegate = self
        statusItem.menu = menu
        statusItem.isVisible = Store.state.hideMenuBar != true
        DistributedNotificationCenter.default().addObserver(
            forName: .init("dev.mouseskins.changed"), object: nil, queue: .main) { [weak self] _ in
            self?.statusItem.isVisible = Store.state.hideMenuBar != true
            Swing.update()
        }

        // Login is the one moment the stock cursors are guaranteed untouched.
        Cursors.captureDefaultsIfClean()
        Store.applySaved()
        Swing.update()

        // WindowServer drops registered cursors on some of these (display
        // reconfig, fast user switching), so re-apply after each one settles.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.screensDidWakeNotification] {
            ws.addObserver(self, selector: #selector(scheduleReapply), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleReapply),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Opened by hand → show the window; at login → stay in the menu bar.
        if !launchedInBackground && !launchedAsLoginItem { PanelProcess.toggle() }
    }

    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    // Opening MouseSkins again (Finder, Raycast, `open -a MouseSkins`) brings the window up.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        PanelProcess.toggle()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func showWindow() { PanelProcess.toggle() }

    @objc private func scheduleReapply() {
        pendingReapply?.cancel()
        let work = DispatchWorkItem { Store.applySaved(); Swing.update() }
        pendingReapply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    // MARK: menu (rebuilt on every open so new themes and CLI changes show up)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = Store.state

        menu.addItem(item("Show Panel", #selector(showWindow)))
        menu.addItem(.separator())

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
        let swing = item("Swing on Click", #selector(toggleSwing))
        swing.state = state.swing == true ? .on : .off
        menu.addItem(swing)
        let plus = item("Crosshair on Tip", #selector(toggleCrosshair))
        plus.state = state.crosshair == true ? .on : .off
        menu.addItem(plus)

        menu.addItem(.separator())
        menu.addItem(item("Import…", #selector(showWindow)))
        menu.addItem(item("Open Themes Folder", #selector(openFolder)))

        menu.addItem(.separator())
        let login = item("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Quit MouseSkins", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    // MARK: actions

    @objc private func applyTheme(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if let problem = Store.use(id) { alert("Couldn't apply \(id)", problem) }
    }

    @objc private func resetCursors() {
        Store.use(nil)
    }

    @objc private func setSize(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Float else { return }
        Store.setScale(v)
    }

    @objc private func toggleSwing() {
        var s = Store.state
        s.swing = s.swing == true ? nil : true
        Store.state = s     // the change notification runs Swing.update()
    }

    @objc private func toggleCrosshair() {
        var s = Store.state
        s.crosshair = s.crosshair == true ? nil : true
        Store.state = s
        if s.theme != nil { Store.applySaved() }
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
