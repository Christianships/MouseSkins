import Foundation
import ServiceManagement

/// `msig <command>`: the same binary as the menu bar app, run with arguments.
enum CLI {
    static let usage = """
    msig — custom cursor themes for macOS

      msig list              themes in the library (* = applied)
      msig apply <theme>     apply a theme and remember it
      msig reset             back to the macOS cursors
      msig scale [size]      show or set cursor size (1 = normal, e.g. 1.5)
      msig import <path>     add a .cape file or theme folder to the library
      msig names             cursor names usable as keys in theme.json
      msig dir               print the themes folder
      msig reapply           re-apply the saved theme (what the app does at login)
      msig login [on|off]    open the menu bar app at login (re-applies your theme)

    Themes: \(Store.themesDir.path)
    """

    static func run(_ args: [String]) -> Int32 {
        let cmd = args.first ?? "help"
        let rest = Array(args.dropFirst())
        switch cmd {
        case "list", "ls":
            let current = Store.state.theme
            let ids = Store.themeIDs()
            if ids.isEmpty { print("no themes yet — `msig import <file.cape>`") }
            for id in ids { print(id == current ? "* \(id)" : "  \(id)") }

        case "apply":
            guard let id = rest.first else { return fail("usage: msig apply <theme>") }
            do {
                let theme = try Store.theme(id)
                let failed = Cursors.apply(theme)
                var s = Store.state
                s.theme = theme.id
                Store.state = s
                if let scale = s.scale { Cursors.scale = scale }
                print("applied \(theme.name) (\(theme.cursors.count - failed.count) cursors)")
                if !failed.isEmpty { return fail("couldn't register: " + failed.joined(separator: ", ")) }
            } catch { return fail(error.localizedDescription) }

        case "reset", "default":
            Cursors.reset()
            var s = Store.state
            s.theme = nil
            Store.state = s
            print("restored macOS cursors")
            if !Cursors.hasSavedDefaults {
                print("note: no saved copy of the stock Arrow/IBeam yet; they come back at next logout")
            }

        case "scale", "size":
            guard let arg = rest.first else { print(String(format: "%.2f", Cursors.scale)); break }
            guard let v = Float(arg), (0.5...16).contains(v) else { return fail("size must be 0.5–16") }
            Cursors.scale = v
            var s = Store.state
            s.scale = v
            Store.state = s
            print(String(format: "cursor size %.2f", v))

        case "import", "add":
            guard let path = rest.first else { return fail("usage: msig import <file.cape | folder>") }
            do {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                print("imported \(try Store.importTheme(from: url)) — `msig apply` it")
            } catch { return fail(error.localizedDescription) }

        case "names":
            for (name, ident) in Cursors.names.sorted(by: { $0.key < $1.key }) {
                print(name.padding(toLength: 18, withPad: " ", startingAt: 0) + ident)
            }

        case "dir":
            print(Store.themesDir.path)

        case "reapply":
            if let problem = Store.applySaved() { return fail(problem) }
            print(Store.state.theme.map { "re-applied \($0)" } ?? "no theme saved; nothing to do")

        case "login":
            let svc = SMAppService.mainApp
            do {
                switch rest.first {
                case "on": try svc.register()
                case "off": try svc.unregister()
                case nil: break
                default: return fail("usage: msig login [on|off]")
                }
            } catch { return fail(error.localizedDescription) }
            print("open at login: " + (svc.status == .enabled ? "on" : svc.status == .requiresApproval
                ? "needs approval in System Settings › General › Login Items" : "off"))

        case "help", "-h", "--help":
            print(usage)

        default:
            return fail("unknown command \"\(cmd)\"\n\n" + usage)
        }
        return 0
    }

    private static func fail(_ msg: String) -> Int32 {
        FileHandle.standardError.write(("msig: " + msg + "\n").data(using: .utf8)!)
        return 1
    }
}
