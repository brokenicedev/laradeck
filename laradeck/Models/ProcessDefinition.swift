import Foundation

nonisolated enum ProcessKind: String, Codable, CaseIterable {
    case serve
    case queueWorker
    case horizon
    case scheduler
    case reverb
    case vite
    case sail
    case custom
    /// Watches folders and runs nested sequence children on change (no shell process).
    case folderWatch

    var defaultName: String {
        switch self {
        case .serve: return "Web Server"
        case .queueWorker: return "Queue Worker"
        case .horizon: return "Horizon"
        case .scheduler: return "Scheduler"
        case .reverb: return "Reverb"
        case .vite: return "Vite"
        case .sail: return "Sail"
        case .custom: return "Custom Process"
        case .folderWatch: return "Folder Watch"
        }
    }

    var systemImage: String {
        switch self {
        case .serve: return "server.rack"
        case .queueWorker: return "tray.full"
        case .horizon: return "gauge.with.dots.needle.67percent"
        case .scheduler: return "clock"
        case .reverb: return "dot.radiowaves.left.and.right"
        case .vite: return "bolt"
        case .sail: return "shippingbox"
        case .custom: return "terminal"
        case .folderWatch: return "folder.badge.gearshape"
        }
    }
}

nonisolated enum ProcessExecutionType: String, Codable, CaseIterable {
    /// Stays alive until stopped; monitored as a running process (e.g. queue:work).
    case longRunning
    /// Runs once and exits on its own (e.g. migrate).
    case oneShot
    /// Appears as a quick action but is never tracked as a persistent process (e.g. optimize:clear).
    case shortcut
    /// Watches folders; while "running" (blue), debounced FS changes start nested sequence children.
    case folderWatch
}

nonisolated enum RestartPolicy: String, Codable, CaseIterable {
    case never
    case onFailure
    case always
}

/// Where a process fits in a project's start/stop sequence — a normal process (grouped and
/// started/stopped the usual way), or a lifecycle hook run once, awaited, before/after the normal
/// processes start, or after they've all been stopped.
nonisolated enum ProcessRole: String, Codable {
    case normal
    case preStart
    case postStart
    case postStop
}

/// A prerequisite process and an optional pause after it reaches running state.
nonisolated struct ProcessDependency: Codable, Hashable, Identifiable {
    var processId: UUID
    /// Seconds to wait after the prerequisite is running before starting the dependent process.
    var delaySeconds: Int = 0

    var id: UUID { processId }

    init(processId: UUID, delaySeconds: Int = 0) {
        self.processId = processId
        self.delaySeconds = max(0, delaySeconds)
    }
}

nonisolated struct ProcessDefinition: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var kind: ProcessKind
    var type: ProcessExecutionType = .longRunning
    var executable: String
    var arguments: [String] = []
    /// nil means "project root".
    var workingDirectory: String?
    var environment: [String: String] = [:]
    var autoStart: Bool = false
    var restartPolicy: RestartPolicy = .never
    var dependsOn: [ProcessDependency] = []
    var port: Int?
    /// nil means the default, built-in "Processes" group. Ignored for hook-role processes, which
    /// live in their own "Pre-start"/"Post-start" sections instead.
    var groupId: UUID?
    /// Optional so processes persisted before this existed decode as `.normal`.
    var role: ProcessRole?
    /// Paths to watch when `type == .folderWatch` (absolute, or relative to the project root).
    var watchPaths: [String] = []
    /// Debounce before firing nested children on filesystem change.
    var watchDebounceMs: Int = 500
    /// When true, Logs accepts keyboard input for this process and play opens Logs automatically.
    var isInteractiveCommand: Bool = false

    var effectiveRole: ProcessRole { role ?? .normal }

    var commandLine: String {
        if type == .folderWatch {
            let paths = watchPaths.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let joined = paths.isEmpty ? "(no paths)" : paths.joined(separator: ", ")
            return "Watch \(joined) · \(max(watchDebounceMs, 0))ms"
        }
        return ([executable] + arguments).joined(separator: " ")
    }

    init(
        id: UUID = UUID(),
        name: String,
        kind: ProcessKind,
        type: ProcessExecutionType = .longRunning,
        executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        autoStart: Bool = false,
        restartPolicy: RestartPolicy = .never,
        dependsOn: [ProcessDependency] = [],
        port: Int? = nil,
        groupId: UUID? = nil,
        role: ProcessRole? = nil,
        watchPaths: [String] = [],
        watchDebounceMs: Int = 500,
        isInteractiveCommand: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.type = type
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.autoStart = autoStart
        self.restartPolicy = restartPolicy
        self.dependsOn = dependsOn
        self.port = port
        self.groupId = groupId
        self.role = role
        self.watchPaths = watchPaths
        self.watchDebounceMs = max(0, watchDebounceMs)
        self.isInteractiveCommand = isInteractiveCommand
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(ProcessKind.self, forKey: .kind)
        type = try container.decodeIfPresent(ProcessExecutionType.self, forKey: .type) ?? .longRunning
        executable = try container.decodeIfPresent(String.self, forKey: .executable) ?? (type == .folderWatch ? "." : "")
        if executable.isEmpty, type == .folderWatch {
            executable = "."
        }
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        restartPolicy = try container.decodeIfPresent(RestartPolicy.self, forKey: .restartPolicy) ?? .never
        if let dependencies = try? container.decode([ProcessDependency].self, forKey: .dependsOn) {
            dependsOn = dependencies
        } else if let legacyIds = try? container.decode([UUID].self, forKey: .dependsOn) {
            dependsOn = legacyIds.map { ProcessDependency(processId: $0) }
        } else {
            dependsOn = []
        }
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        groupId = try container.decodeIfPresent(UUID.self, forKey: .groupId)
        role = try container.decodeIfPresent(ProcessRole.self, forKey: .role)
        watchPaths = try container.decodeIfPresent([String].self, forKey: .watchPaths) ?? []
        watchDebounceMs = try container.decodeIfPresent(Int.self, forKey: .watchDebounceMs) ?? 500
        isInteractiveCommand = try container.decodeIfPresent(Bool.self, forKey: .isInteractiveCommand) ?? false
    }
}

/// Resolves folder-watch paths against a project root.
enum FolderWatchPathResolver {
    nonisolated static func resolve(_ raw: String, projectPath: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("/") {
            return trimmed
        }
        return (projectPath as NSString).appendingPathComponent(trimmed)
    }

    nonisolated static func resolveAll(_ paths: [String], projectPath: String) -> [String] {
        paths
            .map { resolve($0, projectPath: projectPath) }
            .filter { !$0.isEmpty }
    }

    /// Decides how a path should be watched (file vs directory). Missing files with an
    /// extension still become file targets so they work once the build writes them.
    nonisolated static func classify(_ path: String) -> FolderWatchTargetKind? {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        if exists, isDirectory.boolValue {
            return .directory(path)
        }
        if exists, !isDirectory.boolValue {
            return .file(directory: (path as NSString).deletingLastPathComponent, file: path)
        }
        if !(path as NSString).pathExtension.isEmpty {
            let parent = (path as NSString).deletingLastPathComponent
            var parentIsDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: parent, isDirectory: &parentIsDir), parentIsDir.boolValue {
                return .file(directory: parent, file: path)
            }
        }
        return nil
    }

    nonisolated static func fileFingerprint(for path: String) -> FolderWatchFileFingerprint {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        guard exists, !isDirectory.boolValue else {
            return FolderWatchFileFingerprint(exists: false, size: 0, modificationTime: 0, contentHash: 0)
        }
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
        ])
        let size = Int64(values?.fileSize ?? 0)
        let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
        return FolderWatchFileFingerprint(
            exists: true,
            size: size,
            modificationTime: values?.contentModificationDate?.timeIntervalSince1970 ?? 0,
            contentHash: fnv1a64(data ?? Data())
        )
    }

    /// Stable 64-bit hash for change detection (not cryptographic).
    nonisolated private static func fnv1a64(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data.prefix(256_000) {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        hash ^= UInt64(data.count)
        return hash
    }
}

enum FolderWatchTargetKind: Equatable {
    case directory(String)
    /// Watch `directory` but only fire when `file` fingerprint changes.
    case file(directory: String, file: String)
}

struct FolderWatchFileFingerprint: Equatable {
    var exists: Bool
    var size: Int64
    var modificationTime: TimeInterval
    /// FNV-1a of file bytes (capped) so chmod/touch without content change is ignored.
    var contentHash: UInt64
}
