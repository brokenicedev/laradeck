import Foundation

/// An artisan command selectable in the add-project wizard.
struct WizardArtisanOption: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let commandPreview: String
    var isIncluded: Bool
    /// When true, the process lands in the "Other commands" group (excluded from Start All).
    var useOtherCommandsGroup: Bool
    var executionType: ProcessExecutionType
}

/// Tiny box so pipe readers can publish `Data` across queues without actors.
private final class PipeDataBox: @unchecked Sendable {
    var data = Data()
}

/// Discovers artisan commands via `php artisan list --format=json`, filtering out core dev
/// processes and framework scaffolding generators.
nonisolated enum ArtisanCommandDiscovery {
    private static let coreCommandNames: Set<String> = [
        "serve", "queue:work", "queue:listen", "schedule:work", "schedule:run",
        "horizon", "horizon:work", "horizon:pause", "horizon:continue", "horizon:terminate",
        "reverb:start", "reverb:restart",
    ]

    private static let excludedPrefixes = [
        "make:", "model:", "controller:", "event:", "job:", "listener:", "mail:",
        "middleware:", "migration:", "notification:", "observer:", "policy:",
        "provider:", "request:", "resource:", "rule:", "scope:", "seeder:",
        "view:", "stub:", "channel:", "component:", "exception:", "factory:",
        "cast:", "enum:", "interface:", "class:", "trait:", "vendor:", "package:",
    ]

    private static let excludedExact: Set<String> = [
        "help", "list", "completion", "_complete", "env", "env:decrypt", "env:encrypt",
        "inspire", "about", "down", "up", "key:generate", "storage:link",
        "package:discover", "vendor:publish", "route:list", "route:cache", "config:cache",
        "optimize", "optimize:clear", "cache:clear", "config:clear", "view:clear",
        "event:cache", "event:clear", "route:clear", "clear-compiled", "db:show",
        "db:table", "db:monitor", "db:wipe", "schema:dump",
    ]

    static func discover(at path: String, environment: ProjectEnvironment) async -> [WizardArtisanOption] {
        guard LaravelDetector.isLaravelProject(at: path) else { return [] }
        guard let json = await runArtisanList(at: path, environment: environment) else { return [] }

        var options: [WizardArtisanOption] = []

        for command in parseCommands(from: json) {
            guard !command.hidden else { continue }
            guard !shouldExclude(name: command.name) else { continue }

            let preview = commandPreview(name: command.name, environment: environment, path: path)
            options.append(
                WizardArtisanOption(
                    id: command.name,
                    name: command.name,
                    description: command.description,
                    commandPreview: preview,
                    isIncluded: defaultIncluded(name: command.name),
                    useOtherCommandsGroup: defaultOtherGroup(name: command.name),
                    executionType: defaultExecutionType(name: command.name, description: command.description)
                )
            )
        }

        return options.sorted { lhs, rhs in
            if lhs.isIncluded != rhs.isIncluded { return lhs.isIncluded }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func makeProcessDefinition(
        from option: WizardArtisanOption,
        environment: ProjectEnvironment,
        projectPath: String
    ) -> ProcessDefinition {
        let executable = environment == .sail
            ? (RuntimeResolver.shared.sailBinary(inProject: projectPath) ?? "sail")
            : "php"
        let arguments = ["artisan"] + option.name.split(separator: " ").map(String.init)

        return ProcessDefinition(
            name: displayName(for: option.name),
            kind: .custom,
            type: option.executionType,
            executable: executable,
            arguments: arguments,
            autoStart: !option.useOtherCommandsGroup,
            restartPolicy: option.executionType == .longRunning ? .onFailure : .never
        )
    }

    // MARK: - Parsing

    struct ParsedCommand: Equatable {
        let name: String
        let description: String
        let hidden: Bool
    }

    /// Parses Symfony/Laravel `artisan list --format=json` output.
    static func parseCommands(from json: [String: Any]) -> [ParsedCommand] {
        // Symfony/Laravel `list --format=json` shape:
        // { "application": { "name", "version" }, "commands": [ ... ], "namespaces": [ ... ] }
        // Commands are a top-level sibling of `application`, not nested under it.
        let commandEntries = (json["commands"] as? [[String: Any]])
            ?? ((json["application"] as? [String: Any])?["commands"] as? [[String: Any]])
            ?? []

        return commandEntries.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let description = (entry["description"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let hidden = entry["hidden"] as? Bool ?? false
            return ParsedCommand(name: name, description: description, hidden: hidden)
        }
    }

    // MARK: - Process runner

    private static func runArtisanList(at path: String, environment: ProjectEnvironment) async -> [String: Any]? {
        let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
        // Prefer native php for discovery so Sail projects don't spin up Docker just to list commands.
        // Fall back to sail only when php isn't available on the host.
        let artisanInvocation: String
        if environment == .sail {
            artisanInvocation = "php artisan list --format=json 2>/dev/null || ./vendor/bin/sail artisan list --format=json"
        } else {
            artisanInvocation = "php artisan list --format=json"
        }
        let shellCommand = "cd '\(escapedPath)' && \(artisanInvocation)"

        // Must hop off the caller's actor: this is invoked from SwiftUI `.task` (MainActor), and a
        // blocking wait in an `async` function with no prior suspension freezes the UI.
        return await Task.detached {
            Self.runArtisanListProcess(shellCommand: shellCommand)
        }.value
    }

    private static func runArtisanListProcess(shellCommand: String) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ilc", shellCommand]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Drain pipes on background queues *before* waiting — a ~500KB `list --format=json`
        // fills the OS pipe buffer and deadlocks if we only read after `waitUntilExit`.
        let stdoutBox = PipeDataBox()
        let stderrBox = PipeDataBox()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutBox.data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBox.data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        let waitGroup = DispatchGroup()
        waitGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            waitGroup.leave()
        }
        _ = waitGroup.wait(timeout: .now() + 30)
        if process.isRunning {
            process.terminate()
            _ = waitGroup.wait(timeout: .now() + 2)
            return nil
        }
        _ = readGroup.wait(timeout: .now() + 5)

        guard process.terminationStatus == 0 else { return nil }

        let data = extractJSONObjectData(from: stdoutBox.data)
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    /// Login shells sometimes print banners before command output — keep from the first `{`.
    private static func extractJSONObjectData(from data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        if data.first == UInt8(ascii: "{") {
            return data
        }
        guard let text = String(data: data, encoding: .utf8),
              let brace = text.firstIndex(of: "{") else {
            return nil
        }
        return Data(text[brace...].utf8)
    }

    // MARK: - Filters / helpers

    private static func shouldExclude(name: String) -> Bool {
        if coreCommandNames.contains(name) { return true }
        if excludedExact.contains(name) { return true }
        if excludedPrefixes.contains(where: { name.hasPrefix($0) }) { return true }
        return false
    }

    private static func commandPreview(name: String, environment: ProjectEnvironment, path: String) -> String {
        let executable: String
        if environment == .sail {
            executable = RuntimeResolver.shared.sailBinary(inProject: path) ?? "sail"
        } else {
            executable = "php"
        }
        return ([executable, "artisan"] + name.split(separator: " ").map(String.init)).joined(separator: " ")
    }

    private static func displayName(for commandName: String) -> String {
        commandName.split(separator: ":").last.map {
            String($0).split(separator: "-").map(\.capitalized).joined(separator: " ")
        } ?? commandName
    }

    private static func defaultIncluded(name: String) -> Bool {
        false
    }

    private static func defaultOtherGroup(name: String) -> Bool {
        true
    }

    private static func defaultExecutionType(name: String, description: String) -> ProcessExecutionType {
        let haystack = "\(name) \(description)".lowercased()
        if haystack.contains("work") || haystack.contains("listen") || haystack.contains("daemon") {
            return .longRunning
        }
        return .oneShot
    }
}
