import Foundation

/// Builds the auto-proposed set of `ProcessDefinition`s for a newly-imported project, adapting
/// commands to Sail vs. native PHP (spec §11/§16).
nonisolated enum ProcessDefinitionFactory {
    static func proposedProcesses(
        environment: ProjectEnvironment,
        packageManager: PackageManager,
        metadata: LaravelMetadata,
        npmScripts: [String: String] = [:],
        isLaravel: Bool = true,
        includePackageScripts: Bool = false
    ) -> [ProcessDefinition] {
        var definitions: [ProcessDefinition] = []

        func artisan(
            _ arguments: [String],
            kind: ProcessKind,
            name: String,
            port: Int? = nil
        ) -> ProcessDefinition {
            let executable = environment == .sail ? "sail" : "php"
            return ProcessDefinition(
                name: name,
                kind: kind,
                type: .longRunning,
                executable: executable,
                arguments: ["artisan"] + arguments,
                autoStart: true,
                restartPolicy: .onFailure,
                port: port
            )
        }

        if isLaravel {
            // Sail's own containers already serve the app; a native `php artisan serve` isn't needed.
            if environment == .native {
                definitions.append(artisan(["serve"], kind: .serve, name: "Web Server", port: 8000))
            }

            definitions.append(artisan(["queue:work"], kind: .queueWorker, name: "Queue Worker"))
            definitions.append(artisan(["schedule:work"], kind: .scheduler, name: "Scheduler"))

            if metadata.hasHorizon {
                definitions.append(artisan(["horizon"], kind: .horizon, name: "Horizon"))
            }
            if metadata.hasReverb {
                definitions.append(artisan(["reverb:start"], kind: .reverb, name: "Reverb", port: 8080))
            }
        }

        if includePackageScripts, packageManager != .none {
            // If the project defines a "watch" script, it's the one meant to stay running
            // (e.g. `vite build --watch`) — prefer it over "dev" rather than proposing both.
            let preferredScript = npmScripts["watch"] != nil ? "watch" : "dev"
            let hasKnownScripts = !npmScripts.isEmpty
            let shouldPropose = !hasKnownScripts || npmScripts[preferredScript] != nil

            if shouldPropose {
                definitions.append(
                    ProcessDefinition(
                        name: "Vite",
                        kind: .vite,
                        type: .longRunning,
                        executable: packageManager.executableName,
                        arguments: packageManager.runScriptArguments(preferredScript),
                        autoStart: true,
                        restartPolicy: .onFailure,
                        // `build --watch` has no dev server to report a port for.
                        port: preferredScript == "dev" ? 5173 : nil
                    )
                )
            }
        }

        return definitions
    }

    /// Re-points existing artisan-based processes (Web Server, Queue Worker, Scheduler, Horizon,
    /// Reverb) at `php` or `sail` after a manual environment override in Edit Project. Custom
    /// processes and Vite are left untouched — Vite runs on the host either way.
    ///
    /// Some projects have both Sail and a working native PHP set up; the auto-detector can only
    /// guess one default, so this is the escape hatch for switching by hand.
    static func adaptExecutables(_ processes: [ProcessDefinition], to environment: ProjectEnvironment) -> [ProcessDefinition] {
        var updated = processes.map { definition -> ProcessDefinition in
            guard definition.kind != .custom, definition.arguments.first == "artisan" else { return definition }
            var copy = definition
            copy.executable = environment == .sail ? "sail" : "php"
            return copy
        }

        // Switching to native from a Sail-only project leaves no web server — Sail's containers
        // serve the app on their own, so a native project needs `php artisan serve` restored.
        if environment == .native, !updated.contains(where: { $0.kind == .serve }) {
            updated.insert(
                ProcessDefinition(
                    name: "Web Server",
                    kind: .serve,
                    type: .longRunning,
                    executable: "php",
                    arguments: ["artisan", "serve"],
                    autoStart: true,
                    restartPolicy: .onFailure,
                    port: 8000
                ),
                at: 0
            )
        }

        return updated
    }
}
