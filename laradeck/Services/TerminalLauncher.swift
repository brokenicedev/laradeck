import Foundation
import AppKit

/// Supported terminal apps for "Open Terminal" (spec §27).
nonisolated enum TerminalApp: String, Codable, CaseIterable {
    case terminal = "com.apple.Terminal"
    case iterm = "com.googlecode.iterm2"
    case warp = "dev.warp.Warp-Stable"
    case ghostty = "com.mitchellh.ghostty"

    var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .iterm: return "iTerm"
        case .warp: return "Warp"
        case .ghostty: return "Ghostty"
        }
    }
}

nonisolated enum TerminalLauncher {
    /// Log viewer action icon — shared by process rows and Sail container rows.
    static let logsIconSystemName = "doc.text"

    /// Terminal apps actually installed on this Mac, in `TerminalApp` declaration order.
    static func installedTerminals() -> [TerminalApp] {
        TerminalApp.allCases.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.rawValue) != nil
        }
    }

    static func open(_ app: TerminalApp, at path: String) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.rawValue) else { return }
        let directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        NSWorkspace.shared.open(
            [directoryURL],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    /// Opens the preferred terminal and runs an interactive shell inside a Sail compose service.
    static func openContainerShell(_ app: TerminalApp, projectPath: String, service: String) {
        let escapedService = shellEscape(service)
        runCommand(app, """
        cd \(shellEscape(projectPath)) || exit 1
        docker compose exec -it \(escapedService) bash || docker compose exec -it \(escapedService) sh
        """)
    }

    /// Opens the preferred terminal and runs a zsh command line in it (e.g. `psql -p 5432`).
    static func runCommand(_ app: TerminalApp, _ command: String) {
        guard let scriptURL = writeCommandScript(command) else { return }

        switch app {
        case .terminal:
            NSWorkspace.shared.open(scriptURL)
        case .iterm:
            let escapedPath = scriptURL.path
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            runAppleScript("""
            tell application "iTerm"
                activate
                create window with default profile command "\(escapedPath)"
            end tell
            """)
        case .warp, .ghostty:
            openCommandScript(with: app, scriptURL: scriptURL)
        }
    }

    private static func openCommandScript(with app: TerminalApp, scriptURL: URL) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.rawValue) else {
            NSWorkspace.shared.open(scriptURL)
            return
        }
        NSWorkspace.shared.open(
            [scriptURL],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    private static func writeCommandScript(_ command: String) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("laradeck-\(UUID().uuidString).command")
        let script = """
#!/bin/zsh
\(command)

"""
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }

    static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func runAppleScript(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }
}
