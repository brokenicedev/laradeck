import Foundation

/// Applies global command presets to a project's process list.
nonisolated enum CommandPresetApplier {
    static func makeProcesses(from preset: CommandPreset, project: Project) -> [ProcessDefinition] {
        preset.commands.compactMap { line in
            makeProcess(from: line, project: project)
        }
    }

    static func makeProcess(from commandLine: String, project: Project) -> ProcessDefinition? {
        buildProcess(from: commandLine.trimmingCharacters(in: .whitespacesAndNewlines), project: project)
    }

    private static func buildProcess(from line: String, project: Project) -> ProcessDefinition? {
        guard !line.isEmpty else { return nil }
        let parts = splitCommandLine(line)
        guard var executable = parts.first else { return nil }
        var arguments = Array(parts.dropFirst())

        if project.environment == .sail,
           executable == "php",
           arguments.first == "artisan" {
            executable = RuntimeResolver.shared.sailBinary(inProject: project.path) ?? "sail"
            if executable.hasSuffix("sail") {
                // sail artisan ...
            } else {
                arguments = ["artisan"] + Array(arguments.dropFirst())
            }
        }

        let name = displayName(for: line, arguments: arguments)

        return ProcessDefinition(
            name: name,
            kind: .custom,
            type: .shortcut,
            executable: executable,
            arguments: arguments,
            autoStart: false,
            restartPolicy: .never,
            groupId: project.otherCommandsGroupId,
            role: .normal
        )
    }

    private static func splitCommandLine(_ line: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
                continue
            }
            if char == " " && !inQuotes {
                if !current.isEmpty {
                    parts.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            parts.append(current)
        }
        return parts
    }

    private static func displayName(for line: String, arguments: [String]) -> String {
        if arguments.first == "artisan", arguments.count >= 2 {
            return arguments[1].split(separator: ":").last.map {
                String($0).split(separator: "-").map(\.capitalized).joined(separator: " ")
            } ?? arguments[1]
        }
        if arguments.first == "run", arguments.count >= 2 {
            return arguments[1].capitalized
        }
        return (arguments.last ?? line).capitalized
    }
}
