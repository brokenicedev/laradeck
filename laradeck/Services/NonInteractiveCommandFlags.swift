import Foundation

/// Injects non-interactive flags for unattended runs (Start All, hooks, folder-watch children).
nonisolated enum NonInteractiveCommandFlags {
    static func arguments(
        executable: String,
        resolvedExecutablePath: String,
        arguments: [String]
    ) -> [String] {
        let basename = (resolvedExecutablePath as NSString).lastPathComponent
        let exe = executable.hasPrefix("/") ? (executable as NSString).lastPathComponent : executable

        if exe == "php" || basename == "php", arguments.first == "artisan" {
            return injectArtisanFlags(arguments)
        }
        if exe == "composer" || basename == "composer" {
            return injectComposerFlags(arguments)
        }
        return arguments
    }

    private static func injectArtisanFlags(_ arguments: [String]) -> [String] {
        guard arguments.first == "artisan" else { return arguments }
        if arguments.contains("-n") || arguments.contains("--no-interaction") {
            return arguments
        }
        var result = arguments
        result.insert("-n", at: 1)
        return result
    }

    private static func injectComposerFlags(_ arguments: [String]) -> [String] {
        if arguments.contains("--no-interaction") || arguments.contains("-n") {
            return arguments
        }
        var result = arguments
        result.append("--no-interaction")
        return result
    }
}
