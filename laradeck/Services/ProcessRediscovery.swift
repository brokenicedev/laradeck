import Foundation

/// A command detected in the project tree that is not yet configured in Laradeck.
struct RediscoveredCommand: Identifiable, Hashable {
    enum Source: String, Hashable {
        case core
        case script
        case artisan
    }

    let id: String
    let source: Source
    let title: String
    let subtitle: String
    let preview: String
    var isIncluded: Bool
    var useOtherCommandsGroup: Bool

    var sourceBadge: String {
        switch source {
        case .core: return "laravel"
        case .script: return id.hasPrefix("composer:") ? "composer.json" : "package.json"
        case .artisan: return "artisan"
        }
    }
}

/// Finds npm/composer/artisan/core commands missing from a project's process list.
nonisolated enum ProcessRediscovery {
    static func discoverNew(for project: Project) async -> [RediscoveredCommand] {
        let existingKeys = existingMatchKeys(for: project)
        var results: [RediscoveredCommand] = []

        if LaravelDetector.isLaravelProject(at: project.path) {
            let metadata = LaravelDetector.detectMetadata(at: project.path)
            let core = ProcessDefinitionFactory.proposedProcesses(
                environment: project.environment,
                packageManager: project.packageManager,
                metadata: metadata,
                isLaravel: true,
                includePackageScripts: false
            )
            for definition in core {
                let key = matchKey(for: definition, project: project)
                guard !existingKeys.contains(key) else { continue }
                results.append(
                    RediscoveredCommand(
                        id: "core:\(definition.kind.rawValue)",
                        source: .core,
                        title: definition.name,
                        subtitle: definition.kind.defaultName,
                        preview: definition.commandLine,
                        isIncluded: true,
                        useOtherCommandsGroup: false
                    )
                )
            }
        }

        for option in ScriptCommandDiscovery.discover(
            at: project.path,
            environment: project.environment,
            packageManager: project.packageManager
        ) {
            let key = scriptMatchKey(option)
            guard !existingKeys.contains(key) else { continue }
            results.append(
                RediscoveredCommand(
                    id: option.id,
                    source: .script,
                    title: option.name,
                    subtitle: option.sourceLabel,
                    preview: option.commandPreview,
                    isIncluded: option.isIncluded,
                    useOtherCommandsGroup: option.useOtherCommandsGroup
                )
            )
        }

        if LaravelDetector.isLaravelProject(at: project.path) {
            for option in await ArtisanCommandDiscovery.discover(
                at: project.path,
                environment: project.environment
            ) {
                let key = "artisan:\(option.name)"
                guard !existingKeys.contains(key) else { continue }
                results.append(
                    RediscoveredCommand(
                        id: key,
                        source: .artisan,
                        title: option.name,
                        subtitle: option.description,
                        preview: option.commandPreview,
                        isIncluded: false,
                        useOtherCommandsGroup: true
                    )
                )
            }
        }

        return results
    }

    static func makeProcessDefinition(
        from item: RediscoveredCommand,
        project: Project
    ) -> ProcessDefinition? {
        switch item.source {
        case .core:
            guard item.id.hasPrefix("core:") else { return nil }
            let kindRaw = String(item.id.dropFirst("core:".count))
            guard let kind = ProcessKind(rawValue: kindRaw) else { return nil }
            let metadata = LaravelDetector.detectMetadata(at: project.path)
            return ProcessDefinitionFactory.proposedProcesses(
                environment: project.environment,
                packageManager: project.packageManager,
                metadata: metadata,
                isLaravel: true,
                includePackageScripts: false
            ).first { $0.kind == kind }

        case .script:
            guard let option = ScriptCommandDiscovery.discover(
                at: project.path,
                environment: project.environment,
                packageManager: project.packageManager
            ).first(where: { $0.id == item.id }) else { return nil }
            var copy = option
            copy.isIncluded = true
            copy.useOtherCommandsGroup = item.useOtherCommandsGroup
            return ScriptCommandDiscovery.makeProcessDefinition(
                from: copy,
                environment: project.environment,
                packageManager: project.packageManager
            )

        case .artisan:
            guard item.id.hasPrefix("artisan:") else { return nil }
            let name = String(item.id.dropFirst("artisan:".count))
            let option = WizardArtisanOption(
                id: name,
                name: name,
                description: item.subtitle,
                commandPreview: item.preview,
                isIncluded: true,
                useOtherCommandsGroup: item.useOtherCommandsGroup,
                executionType: .oneShot
            )
            return ArtisanCommandDiscovery.makeProcessDefinition(
                from: option,
                environment: project.environment,
                projectPath: project.path
            )
        }
    }

    private static func existingMatchKeys(for project: Project) -> Set<String> {
        Set(project.processes.map { matchKey(for: $0, project: project) })
    }

    private static func matchKey(for definition: ProcessDefinition, project: Project) -> String {
        if definition.kind != .custom {
            return "kind:\(definition.kind.rawValue)"
        }
        if definition.arguments.first == "artisan", definition.arguments.count >= 2 {
            return "artisan:\(definition.arguments[1])"
        }
        if let scriptName = npmScriptName(from: definition, packageManager: project.packageManager) {
            return "npm:\(scriptName)"
        }
        if definition.executable == "composer" || definition.arguments.first == "run-script" {
            if let name = definition.arguments.last {
                return "composer:\(name)"
            }
        }
        if definition.executable.hasSuffix("sail"), definition.arguments.first == "composer",
           definition.arguments.count >= 3, definition.arguments[1] == "run-script" {
            return "composer:\(definition.arguments[2])"
        }
        return "cmd:\(definition.commandLine.lowercased())"
    }

    private static func scriptMatchKey(_ option: WizardScriptOption) -> String {
        option.id
    }

    private static func npmScriptName(from definition: ProcessDefinition, packageManager: PackageManager) -> String? {
        guard definition.executable == packageManager.executableName else { return nil }
        let args = packageManager.runScriptArguments("placeholder")
        guard args.count >= 1 else { return nil }
        if args[0] == "run", definition.arguments.first == "run", definition.arguments.count >= 2 {
            return definition.arguments[1]
        }
        if args[0] != "run", definition.arguments.count == 1 {
            return definition.arguments[0]
        }
        return nil
    }
}
