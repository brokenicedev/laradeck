import Foundation

/// A script entry from package.json or composer.json, selectable in the add-project wizard.
struct WizardScriptOption: Identifiable, Hashable {
    enum Source: String, Hashable {
        case npm
        case composer
    }

    let id: String
    let source: Source
    let name: String
    let commandPreview: String
    var isIncluded: Bool
    /// When true, the process lands in the "Other commands" group (excluded from Start All).
    var useOtherCommandsGroup: Bool
    var executionType: ProcessExecutionType

    var sourceLabel: String {
        switch source {
        case .npm: return "package.json"
        case .composer: return "composer.json"
        }
    }
}

/// Discovers npm/composer scripts and builds wizard rows with sensible defaults.
nonisolated enum ScriptCommandDiscovery {
    static let otherCommandsGroupName = "Other commands"

    /// Limits which scripts appear during project import (npm + composer).
    enum ScriptImportScope {
        case devAndWatchOnly
        case all
    }

    static func discover(
        at path: String,
        environment: ProjectEnvironment,
        packageManager: PackageManager,
        importScope: ScriptImportScope = .all
    ) -> [WizardScriptOption] {
        var options: [WizardScriptOption] = []

        for (name, command) in NpmScriptsDetector.scripts(at: path).sorted(by: { $0.key < $1.key }) {
            if importScope == .devAndWatchOnly {
                let lower = name.lowercased()
                guard lower == "dev" || lower == "watch" else { continue }
            }
            let preview = ([packageManager.executableName] + packageManager.runScriptArguments(name)).joined(separator: " ")
            options.append(
                WizardScriptOption(
                    id: "npm:\(name)",
                    source: .npm,
                    name: name,
                    commandPreview: preview,
                    isIncluded: defaultNpmIncluded(name: name, importScope: importScope),
                    useOtherCommandsGroup: defaultNpmOtherGroup(name: name, importScope: importScope),
                    executionType: defaultExecutionType(name: name, command: command)
                )
            )
        }

        for (name, command) in ComposerScriptsDetector.scripts(at: path).sorted(by: { $0.key < $1.key }) {
            if importScope == .devAndWatchOnly {
                let lower = name.lowercased()
                guard lower == "dev" || lower == "watch" else { continue }
            }
            let executable = environment == .sail ? "sail" : "composer"
            let arguments = environment == .sail ? ["composer", "run-script", name] : ["run-script", name]
            let preview = ([executable] + arguments).joined(separator: " ")
            options.append(
                WizardScriptOption(
                    id: "composer:\(name)",
                    source: .composer,
                    name: name,
                    commandPreview: preview,
                    isIncluded: defaultComposerIncluded(name: name, importScope: importScope),
                    useOtherCommandsGroup: defaultComposerOtherGroup(importScope: importScope),
                    executionType: defaultExecutionType(name: name, command: command)
                )
            )
        }

        return options
    }

    static func makeProcessDefinition(
        from option: WizardScriptOption,
        environment: ProjectEnvironment,
        packageManager: PackageManager
    ) -> ProcessDefinition {
        switch option.source {
        case .npm:
            return ProcessDefinition(
                name: displayName(for: option.name),
                kind: option.name == "dev" || option.name == "watch" ? .vite : .custom,
                type: option.executionType,
                executable: packageManager.executableName,
                arguments: packageManager.runScriptArguments(option.name),
                autoStart: !option.useOtherCommandsGroup,
                restartPolicy: option.executionType == .longRunning ? .onFailure : .never,
                port: option.name == "dev" ? 5173 : nil
            )
        case .composer:
            let executable = environment == .sail ? "sail" : "composer"
            let arguments = environment == .sail ? ["composer", "run-script", option.name] : ["run-script", option.name]
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
    }

    private static func displayName(for scriptName: String) -> String {
        scriptName.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }

    private static func defaultNpmIncluded(name: String, importScope: ScriptImportScope) -> Bool {
        let lower = name.lowercased()
        return lower == "dev" || lower == "watch"
    }

    private static func defaultNpmOtherGroup(name: String, importScope: ScriptImportScope) -> Bool {
        let lower = name.lowercased()
        if lower == "dev" || lower == "watch" { return true }
        if importScope == .devAndWatchOnly { return true }
        return defaultLegacyOtherGroup(name: name)
    }

    /// Composer scripts: only `dev` and `watch` are pre-selected during import.
    private static func defaultComposerIncluded(name: String, importScope: ScriptImportScope) -> Bool {
        let lower = name.lowercased()
        return lower == "dev" || lower == "watch"
    }

    private static func defaultComposerOtherGroup(importScope: ScriptImportScope) -> Bool {
        true
    }

    private static func defaultLegacyOtherGroup(name: String) -> Bool {
        let lower = name.lowercased()
        if lower == "dev" || lower == "watch" { return true }
        if ["serve", "start"].contains(where: { lower.contains($0) }) {
            return false
        }
        return true
    }

    private static func defaultExecutionType(name: String, command: String) -> ProcessExecutionType {
        let haystack = "\(name) \(command)".lowercased()
        // Builds run once and exit — but their exit code matters (a failed build is a failed
        // build), and they're a reasonable Start All prerequisite, so they're tracked like any
        // other one-shot rather than treated as a fire-and-forget Shortcut.
        if haystack.contains("build") && !haystack.contains("watch") { return .oneShot }
        if haystack.contains("test") || haystack.contains("lint") || haystack.contains("analyse") {
            return .shortcut
        }
        return .longRunning
    }
}
