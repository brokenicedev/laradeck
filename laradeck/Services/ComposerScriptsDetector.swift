import Foundation

/// Reads the `scripts` block of a project's composer.json for wizard import.
nonisolated enum ComposerScriptsDetector {
    /// Composer lifecycle hooks — not useful as standalone runnable commands in Laradeck.
    static let ignoredScriptNames: Set<String> = [
        "post-autoload-dump",
        "post-update-cmd",
        "post-root-package-install",
        "post-create-project-cmd",
        "pre-autoload-dump",
        "post-install-cmd",
        "post-package-install",
    ]

    static func scripts(at projectPath: String) -> [String: String] {
        guard let composer = LaravelDetector.readComposerJSON(at: projectPath),
              let raw = composer["scripts"] as? [String: Any] else {
            return [:]
        }

        var result: [String: String] = [:]
        for (name, value) in raw where !ignoredScriptNames.contains(name) {
            if let command = value as? String {
                result[name] = command
            } else if let lines = value as? [String], let first = lines.first {
                result[name] = first
            }
        }
        return result
    }
}
