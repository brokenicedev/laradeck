import Foundation

/// Portable team config written to `<project>/.laradeck` — safe to commit (no secrets, no absolute paths).
nonisolated struct LaradeckProjectProfile: Codable, Hashable {
    static let currentVersion = 1

    var version: Int
    var name: String
    var environment: ProjectEnvironment
    var packageManager: PackageManager
    var url: String?
    var tags: [String]
    var colorHex: String?
    var iconStyle: ProjectIconStyle?
    var autoStartOnLaunch: Bool?
    var processGroups: [ProcessGroup]?
    var processes: [ProcessDefinition]
    var startupSequence: [StartupSequenceNode]?

    init(
        version: Int = Self.currentVersion,
        name: String,
        environment: ProjectEnvironment,
        packageManager: PackageManager,
        url: String? = nil,
        tags: [String] = [],
        colorHex: String? = nil,
        iconStyle: ProjectIconStyle? = nil,
        autoStartOnLaunch: Bool? = nil,
        processGroups: [ProcessGroup]? = nil,
        processes: [ProcessDefinition] = [],
        startupSequence: [StartupSequenceNode]? = nil
    ) {
        self.version = version
        self.name = name
        self.environment = environment
        self.packageManager = packageManager
        self.url = url
        self.tags = tags
        self.colorHex = colorHex
        self.iconStyle = iconStyle
        self.autoStartOnLaunch = autoStartOnLaunch
        self.processGroups = processGroups
        self.processes = processes
        self.startupSequence = startupSequence
    }

    /// Builds a profile from the live project (machine-local fields stripped).
    static func from(project: Project) -> LaradeckProjectProfile {
        LaradeckProjectProfile(
            name: project.name,
            environment: project.environment,
            packageManager: project.packageManager,
            url: project.url,
            tags: project.tags,
            colorHex: project.colorHex ?? project.effectiveColorHex,
            iconStyle: project.iconStyle == .customImage ? .initials : project.iconStyle,
            autoStartOnLaunch: project.autoStartOnLaunch,
            processGroups: project.processGroups,
            processes: project.processes,
            startupSequence: project.startupSequence
        )
    }

    /// Materializes a `Project` for the given folder. Process / group IDs from the file are kept
    /// so `dependsOn` and `startupSequence` stay coherent across machines.
    func toProject(path: String) -> Project {
        var project = Project(
            name: name,
            path: path,
            environment: environment,
            packageManager: packageManager,
            processes: processes
        )
        project.url = url
        project.tags = tags
        project.colorHex = colorHex
        project.iconStyle = iconStyle ?? .initials
        project.autoStartOnLaunch = autoStartOnLaunch ?? false
        project.processGroups = processGroups
        project.startupSequence = startupSequence
        project.ensureOtherCommandsGroup()
        return project
    }
}
