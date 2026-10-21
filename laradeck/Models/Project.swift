import Foundation

nonisolated enum ProjectEnvironment: String, Codable, CaseIterable {
    case native
    case sail
}

nonisolated enum PackageManager: String, Codable, CaseIterable {
    case npm
    case pnpm
    case yarn
    case bun
    case none

    /// The subcommand used to run an arbitrary package.json script, e.g. "npm run dev".
    func runScriptArguments(_ script: String) -> [String] {
        switch self {
        case .npm: return ["run", script]
        case .pnpm: return [script]
        case .yarn: return [script]
        case .bun: return ["run", script]
        case .none: return []
        }
    }

    var executableName: String {
        switch self {
        case .npm: return "npm"
        case .pnpm: return "pnpm"
        case .yarn: return "yarn"
        case .bun: return "bun"
        case .none: return ""
        }
    }
}

nonisolated enum ProjectIconStyle: String, Codable, CaseIterable {
    /// A user-selected image copied into Laradeck storage (PNG, SVG, …).
    case customImage
    /// A colored initials avatar.
    case initials

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case Self.customImage.rawValue:
            self = .customImage
        case Self.initials.rawValue, "favicon":
            self = .initials
        default:
            self = .initials
        }
    }
}

/// A small curated palette for the initials-avatar background, picked deterministically from the
/// project name so projects get a stable, distinct color even before anyone chooses one by hand.
nonisolated enum ProjectColorPalette {
    static let hexValues = [
        "FB563D", "F59E0B", "10B981", "3B82F6",
        "8B5CF6", "EC4899", "14B8A6", "EF4444",
        "6366F1", "F97316", "06B6D4", "84CC16",
    ]

    static func defaultHex(for seed: String) -> String {
        hexValues[stableHash(seed) % hexValues.count]
    }

    /// `String.hashValue` is randomized per process launch — not usable here, since the same
    /// project needs to land on the same color every time this is called as a fallback.
    private static func stableHash(_ string: String) -> Int {
        var hash = 5381
        for byte in string.utf8 {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        return abs(hash)
    }
}

/// A user-defined bucket for organizing custom processes beyond the built-in "Processes" list
/// (which is implicit — a `ProcessDefinition` with `groupId == nil` belongs to it).
nonisolated struct ProcessGroup: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// Processes in this group are omitted from Start All (e.g. manual utility scripts).
    /// Stop All still stops them when they are running.
    var excludedFromStartAll: Bool = false
}

nonisolated struct Project: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var path: String
    var environment: ProjectEnvironment
    var packageManager: PackageManager
    var processes: [ProcessDefinition] = []
    var favorite: Bool = false
    var tags: [String] = []
    var url: String?
    var autoStartOnLaunch: Bool = false
    /// Which sidebar group this project is filed under; nil means it sits in the ungrouped list.
    var sidebarGroupId: UUID?

    // Cached metadata, refreshed on demand — not authoritative.
    var laravelVersion: String?
    var phpVersion: String?
    var hasHorizon: Bool = false
    var hasReverb: Bool = false
    /// Node version (e.g. "20.19.2") from nvm the project's processes run with; nil = nvm default.
    var nodeVersion: String?

    // Optional so projects persisted before this setting existed still decode fine.
    var iconStyle: ProjectIconStyle?
    /// Absolute path to a user-imported logo in Application Support.
    var customIconPath: String?
    var colorHex: String?
    var processGroups: [ProcessGroup]?
    /// Visual Start All timeline — order, pauses, and nested attachments.
    var startupSequence: [StartupSequenceNode]?

    var effectiveIconStyle: ProjectIconStyle {
        if iconStyle == .customImage,
           let path = customIconPath,
           FileManager.default.fileExists(atPath: path) {
            return .customImage
        }
        return .initials
    }
    var effectiveColorHex: String { colorHex ?? ProjectColorPalette.defaultHex(for: name) }
    var effectiveProcessGroups: [ProcessGroup] { processGroups ?? [] }

    /// True when the project directory contains a Docker Compose file (Sail or plain `docker compose`).
    var hasDockerCompose: Bool {
        SailDetector.hasComposeFile(at: path)
    }

    /// Ensures the built-in "Other commands" group exists (excluded from Start All).
    mutating func ensureOtherCommandsGroup() {
        guard !effectiveProcessGroups.contains(where: { $0.name == ScriptCommandDiscovery.otherCommandsGroupName }) else {
            return
        }
        var groups = effectiveProcessGroups
        groups.append(
            ProcessGroup(
                name: ScriptCommandDiscovery.otherCommandsGroupName,
                excludedFromStartAll: true
            )
        )
        processGroups = groups
    }

    var otherCommandsGroupId: UUID? {
        effectiveProcessGroups.first { $0.name == ScriptCommandDiscovery.otherCommandsGroupName }?.id
    }

    /// Whether this process is driven by the project's Start All action.
    func isIncludedInStartAll(_ definition: ProcessDefinition) -> Bool {
        guard definition.type != .shortcut, definition.effectiveRole == .normal else { return false }
        guard let groupId = definition.groupId else { return true }
        let group = effectiveProcessGroups.first { $0.id == groupId }
        return !(group?.excludedFromStartAll ?? false)
    }

    /// Stop All also tears down anything running outside the tracked Start All set — Other
    /// commands, an excluded custom group, whatever — not just the official set, since the goal
    /// is "stop everything currently running", not "stop only what Start All would have started".
    func isIncludedInStopAll(_ definition: ProcessDefinition) -> Bool {
        definition.effectiveRole == .normal
    }

    /// Process ids that appear nested (depth > 0) in the Start All sequence.
    func nestedStartupProcessIds() -> Set<UUID> {
        Set(
            StartupSequence.flattenedRows(effectiveStartupSequence)
                .compactMap { row -> UUID? in
                    guard row.depth > 0, case .process(let id) = row.kind else { return nil }
                    return id
                }
        )
    }

    /// One-click / on-demand processes in the "Other commands" group.
    func isOtherCommand(_ definition: ProcessDefinition) -> Bool {
        guard definition.effectiveRole == .normal,
              let groupId = definition.groupId,
              let otherId = otherCommandsGroupId else {
            return false
        }
        return groupId == otherId
    }

    mutating func ensureStartupSequence() {
        if startupSequence == nil || startupSequence?.isEmpty == true {
            startupSequence = StartupSequence.defaultSequence(for: self)
        }
        if var sequence = startupSequence {
            StartupSequence.sync(into: &sequence, project: self)
            startupSequence = sequence
        }
    }

    var effectiveStartupSequence: [StartupSequenceNode] {
        var copy = startupSequence ?? StartupSequence.defaultSequence(for: self)
        StartupSequence.sync(into: &copy, project: self)
        return copy
    }

    /// Sorts processes by the persisted Start All order; unknown processes append at the end.
    func sortedByStartOrder(_ processes: [ProcessDefinition]) -> [ProcessDefinition] {
        let order = StartupSequence.collectProcessIds(effectiveStartupSequence)
        return processes.sorted { lhs, rhs in
            let left = order.firstIndex(of: lhs.id)
            let right = order.firstIndex(of: rhs.id)
            switch (left, right) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    var directoryURL: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Prefers the project's own APP_URL, but many freshly-scaffolded Laravel apps leave that at
    /// "http://localhost" with no port — falling back to the Web Server process's port keeps
    /// "Open Browser" working even then.
    var effectiveURL: URL? {
        if let url, let linkURL = URL(string: url) {
            return linkURL
        }
        if let servePort = processes.first(where: { $0.kind == .serve })?.port {
            return URL(string: "http://127.0.0.1:\(servePort)")
        }
        return nil
    }

    func process(withId id: UUID) -> ProcessDefinition? {
        processes.first { $0.id == id }
    }

    /// Processes that must be running before `definition` can start.
    func dependencies(of definition: ProcessDefinition) -> [ProcessDefinition] {
        definition.dependsOn.compactMap { process(withId: $0.processId) }
    }

    /// Resolved prerequisites with their configured delays.
    func dependencyEntries(of definition: ProcessDefinition) -> [(dependency: ProcessDependency, process: ProcessDefinition)] {
        definition.dependsOn.compactMap { entry in
            process(withId: entry.processId).map { (entry, $0) }
        }
    }

    /// Processes that list `definition` in their `dependsOn`.
    func dependents(of definition: ProcessDefinition) -> [ProcessDefinition] {
        processes.filter {
            $0.dependsOn.contains { $0.processId == definition.id } && $0.id != definition.id
        }
    }

    /// Human-readable bucket name for a process (Processes, Other commands, Pre-start, …).
    func destinationLabel(for definition: ProcessDefinition) -> String {
        switch definition.effectiveRole {
        case .preStart: return "Pre-start"
        case .postStart: return "Post-start"
        case .postStop: return "Post-stop"
        case .normal:
            if let groupId = definition.groupId,
               let group = effectiveProcessGroups.first(where: { $0.id == groupId }) {
                return group.name
            }
            return "Processes"
        }
    }
}
