import Foundation

/// Checks `npm run <script>` (and pnpm / yarn / bun) before launching, so a missing script or
/// a wrong working directory fails once with a clear message instead of a restart loop.
nonisolated enum PackageScriptPreflight {
    static let packageManagers: Set<String> = ["npm", "pnpm", "yarn", "bun"]

    /// The script a command runs, e.g. `watch` for `npm run watch`. Nil when it isn't a script run.
    static func scriptName(executable: String, arguments: [String]) -> String? {
        let tool = (executable as NSString).lastPathComponent
        guard packageManagers.contains(tool), arguments.count >= 2 else { return nil }
        guard arguments[0] == "run" || arguments[0] == "run-script" else { return nil }
        let script = arguments[1]
        return script.hasPrefix("-") ? nil : script
    }

    /// An error message when the command can't work in `directory`, nil when it looks fine
    /// (or when the command isn't a package script run).
    static func problem(executable: String, arguments: [String], directory: String) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "Working directory not found: \(directory)"
        }
        guard let script = scriptName(executable: executable, arguments: arguments) else { return nil }

        let packageURL = URL(fileURLWithPath: directory).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL) else {
            return "No package.json in \(directory), so \"\(script)\" can't run. Check the process's working directory."
        }
        // An unreadable package.json is left for the package manager to report.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let scripts = (json["scripts"] as? [String: Any]) ?? [:]
        guard scripts[script] == nil else { return nil }

        let available = scripts.keys.sorted()
        var message = "Script \"\(script)\" isn't defined in \(packageURL.path)."
        message += available.isEmpty
            ? " That package.json has no scripts."
            : " Available scripts: \(available.joined(separator: ", "))."
        message += " Check the script name or the process's working directory."
        return message
    }
}
