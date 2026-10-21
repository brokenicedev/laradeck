import Darwin
import Foundation

/// A host port this project expects to publish or bind when starting.
nonisolated struct ProjectPortRequirement: Equatable, Identifiable, Sendable {
    var id: String { "\(key):\(port)" }
    /// Env key (`APP_PORT`) or synthetic id (`process:vite`).
    var key: String
    var label: String
    var port: Int
    /// When true, a free-port suggestion can be written into `.env` as `key=port`.
    var isEnvWritable: Bool
}

nonisolated struct PortConflict: Equatable, Identifiable, Sendable {
    var id: String { "\(port)-\(requirement.key)" }
    var port: Int
    var requirement: ProjectPortRequirement
    var reason: String
}

nonisolated struct PortConflictReport: Equatable, Sendable {
    var projectId: UUID
    var projectName: String
    var conflicts: [PortConflict]
    /// Suggested `.env` lines for writable keys (copy-paste).
    var suggestedEnvSnippet: String

    var isEmpty: Bool { conflicts.isEmpty }
}

nonisolated enum PortConflictIntent: String, Sendable {
    case composeUp
    case startAll
}

/// Pending UI prompt when Compose Up / Start All hits occupied host ports.
struct PendingPortConflict: Identifiable, Equatable {
    let id: UUID
    var report: PortConflictReport
    var intent: PortConflictIntent

    init(id: UUID = UUID(), report: PortConflictReport, intent: PortConflictIntent) {
        self.id = id
        self.report = report
        self.intent = intent
    }
}

/// Detects host-port collisions before Compose Up / Start All (Sail multi-project pain point).
nonisolated enum PortConflictService {
    /// Common Sail / Compose forwarded ports and their defaults when unset in `.env`.
    private static let sailForwardPorts: [(key: String, defaultPort: Int, label: String)] = [
        ("APP_PORT", 80, "App"),
        ("VITE_PORT", 5173, "Vite"),
        ("FORWARD_DB_PORT", 3306, "Database"),
        ("FORWARD_REDIS_PORT", 6379, "Redis"),
        ("FORWARD_MAILPIT_DASHBOARD_PORT", 8025, "Mailpit"),
        ("FORWARD_MAILHOG_DASHBOARD_PORT", 8025, "Mailhog"),
        ("FORWARD_MAILPIT_PORT", 1025, "Mailpit SMTP"),
        ("FORWARD_MAILHOG_PORT", 1025, "Mailhog SMTP"),
        ("FORWARD_MEILISEARCH_PORT", 7700, "Meilisearch"),
        ("FORWARD_MINIO_PORT", 9000, "MinIO"),
        ("FORWARD_MINIO_CONSOLE_PORT", 8900, "MinIO console"),
        ("XDEBUG_PORT", 9003, "Xdebug"),
    ]

    // MARK: - Public API

    /// Builds a conflict report, or `nil` when nothing blocks startup.
    static func report(
        for project: Project,
        allProjects: [Project],
        dockerStatuses: [UUID: [DockerServiceStatus]],
        runningProcessPorts: [(projectId: UUID, projectName: String, processName: String, port: Int)],
        includeComposePorts: Bool,
        includeProcessPorts: Bool,
        databasePorts: [Int: String] = [:]
    ) -> PortConflictReport? {
        var requirements = requiredPorts(
            for: project,
            includeComposePorts: includeComposePorts,
            includeProcessPorts: includeProcessPorts
        )
        requirements = dedupeRequirements(requirements)
        guard !requirements.isEmpty else { return nil }

        let ownProcessPorts = runningProcessPorts.filter { $0.projectId == project.id }.map(\.port)
        let ownOccupied = occupiedPorts(
            ownedBy: project.id,
            dockerStatuses: dockerStatuses,
            processPorts: ownProcessPorts
        )
        let foreignDocker = foreignDockerPortOwners(
            excluding: project.id,
            dockerStatuses: dockerStatuses,
            projects: allProjects
        )
        let foreignProcesses = Dictionary(
            grouping: runningProcessPorts.filter { $0.projectId != project.id },
            by: \.port
        )

        var conflicts: [PortConflict] = []
        var avoid = Set(requirements.map(\.port))
        avoid.formUnion(foreignDocker.keys)
        avoid.formUnion(foreignProcesses.keys)

        for requirement in requirements {
            if ownOccupied.contains(requirement.port) {
                continue
            }

            if let owner = foreignDocker[requirement.port] {
                conflicts.append(
                    PortConflict(
                        port: requirement.port,
                        requirement: requirement,
                        reason: "Used by \(owner)"
                    )
                )
                continue
            }

            if let owners = foreignProcesses[requirement.port], let first = owners.first {
                let label = owners.count == 1
                    ? "\(first.projectName) · \(first.processName)"
                    : "\(first.projectName) · \(first.processName) (+ \(owners.count - 1) more)"
                conflicts.append(
                    PortConflict(
                        port: requirement.port,
                        requirement: requirement,
                        reason: "Used by \(label)"
                    )
                )
                continue
            }

            if let database = databasePorts[requirement.port] {
                conflicts.append(
                    PortConflict(
                        port: requirement.port,
                        requirement: requirement,
                        reason: "Used by Laradeck database \(database)"
                    )
                )
                continue
            }

            if isPortInUse(requirement.port) {
                conflicts.append(
                    PortConflict(
                        port: requirement.port,
                        requirement: requirement,
                        reason: "Already in use on this Mac"
                    )
                )
            }
        }

        guard !conflicts.isEmpty else { return nil }

        let snippet = suggestedEnvSnippet(for: conflicts, avoiding: &avoid)
        return PortConflictReport(
            projectId: project.id,
            projectName: project.name,
            conflicts: conflicts,
            suggestedEnvSnippet: snippet
        )
    }

    static func requiredPorts(
        for project: Project,
        includeComposePorts: Bool,
        includeProcessPorts: Bool
    ) -> [ProjectPortRequirement] {
        var result: [ProjectPortRequirement] = []
        let env = envMap(at: project.path)

        if includeComposePorts, project.hasDockerCompose {
            result.append(contentsOf: composePortRequirements(projectPath: project.path, env: env, isSail: project.environment == .sail))
        }

        if includeProcessPorts {
            for definition in project.processes where project.isIncludedInStartAll(definition) {
                guard let port = definition.port, port > 0 else { continue }
                result.append(
                    ProjectPortRequirement(
                        key: "process:\(definition.id.uuidString)",
                        label: definition.name,
                        port: port,
                        isEnvWritable: false
                    )
                )
            }
        }

        return result
    }

    /// Returns `true` when something is already listening on `127.0.0.1:port`.
    static func isPortInUse(_ port: Int) -> Bool {
        guard (1...65_535).contains(port) else { return false }

        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if bindResult == 0 {
            return false
        }
        return errno == EADDRINUSE
    }

    static func suggestFreePort(startingFrom preferred: Int, avoiding: inout Set<Int>) -> Int {
        var candidate = max(preferred, 1)
        // Prefer staying near the original (APP_PORT 80 → 81…, DB 3306 → 3307…).
        for _ in 0..<500 {
            if !avoiding.contains(candidate), !isPortInUse(candidate) {
                avoiding.insert(candidate)
                return candidate
            }
            candidate += 1
            if candidate > 65_535 {
                candidate = 1024
            }
        }
        avoiding.insert(preferred)
        return preferred
    }

    static func suggestedEnvSnippet(for conflicts: [PortConflict], avoiding: inout Set<Int>) -> String {
        var lines: [String] = []
        var seenKeys = Set<String>()
        for conflict in conflicts {
            let requirement = conflict.requirement
            guard requirement.isEnvWritable, seenKeys.insert(requirement.key).inserted else { continue }
            let free = suggestFreePort(startingFrom: requirement.port + 1, avoiding: &avoiding)
            lines.append("\(requirement.key)=\(free)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Compose / .env

    static func envMap(at projectPath: String) -> [String: String] {
        let url = URL(fileURLWithPath: projectPath, isDirectory: true).appendingPathComponent(".env")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var map: [String: String] = [:]
        for variable in EnvFileCodec.parse(contents) {
            map[variable.key] = variable.value
        }
        return map
    }

    static func composePortRequirements(
        projectPath: String,
        env: [String: String],
        isSail: Bool
    ) -> [ProjectPortRequirement] {
        var byKey: [String: ProjectPortRequirement] = [:]

        if let composeText = readComposeFile(at: projectPath) {
            for match in extractComposePortExpressions(from: composeText) {
                let port: Int
                if let value = env[match.variable], let parsed = Int(value), parsed > 0 {
                    port = parsed
                } else {
                    port = match.defaultPort
                }
                byKey[match.variable] = ProjectPortRequirement(
                    key: match.variable,
                    label: label(forEnvKey: match.variable),
                    port: port,
                    isEnvWritable: true
                )
            }
        }

        // Sail projects: fill in common forwards only when compose actually references them.
        // Do not assume MySQL/Redis/Mailpit are published — many Sail apps drop those services
        // and use host Redis / shared DB (e.g. REDIS_HOST=host.docker.internal).
        if isSail {
            let composeText = readComposeFile(at: projectPath) ?? ""
            for entry in sailForwardPorts {
                if byKey[entry.key] != nil { continue }
                // Skip Mailhog keys when Mailpit is already present (and vice versa).
                if entry.key.contains("MAILHOG"), byKey.keys.contains(where: { $0.contains("MAILPIT") }) {
                    continue
                }
                if entry.key.contains("MAILPIT"), byKey.keys.contains(where: { $0.contains("MAILHOG") }) {
                    continue
                }
                guard composeText.contains(entry.key) else { continue }

                let port: Int
                if let value = env[entry.key], let parsed = Int(value), parsed > 0 {
                    port = parsed
                } else if env[entry.key] == nil {
                    // Unset → Sail default. Explicit empty string: skip.
                    port = entry.defaultPort
                } else {
                    continue
                }

                byKey[entry.key] = ProjectPortRequirement(
                    key: entry.key,
                    label: entry.label,
                    port: port,
                    isEnvWritable: true
                )
            }
        }

        return Array(byKey.values).sorted { $0.port < $1.port }
    }

    private static func label(forEnvKey key: String) -> String {
        sailForwardPorts.first { $0.key == key }?.label ?? key
    }

    private static func readComposeFile(at projectPath: String) -> String? {
        let names = ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"]
        for name in names {
            let url = URL(fileURLWithPath: projectPath, isDirectory: true).appendingPathComponent(name)
            if let contents = try? String(contentsOf: url, encoding: .utf8) {
                return contents
            }
        }
        return nil
    }

    /// Matches `${APP_PORT:-80}` and `${FORWARD_DB_PORT:-3306}` style mappings.
    static func extractComposePortExpressions(from composeText: String) -> [(variable: String, defaultPort: Int)] {
        let pattern = #"\$\{([A-Z][A-Z0-9_]*)\:\-(\d+)\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(composeText.startIndex..<composeText.endIndex, in: composeText)
        var results: [(String, Int)] = []
        var seen = Set<String>()
        regex.enumerateMatches(in: composeText, range: range) { match, _, _ in
            guard let match,
                  let varRange = Range(match.range(at: 1), in: composeText),
                  let portRange = Range(match.range(at: 2), in: composeText),
                  let port = Int(composeText[portRange]) else { return }
            let variable = String(composeText[varRange])
            guard seen.insert(variable).inserted else { return }
            results.append((variable, port))
        }
        return results
    }

    // MARK: - Ownership helpers

    private static func occupiedPorts(
        ownedBy projectId: UUID,
        dockerStatuses: [UUID: [DockerServiceStatus]],
        processPorts: [Int]
    ) -> Set<Int> {
        var ports = Set(dockerStatuses[projectId]?.flatMap(\.ports) ?? [])
        ports.formUnion(processPorts)
        return ports
    }

    private static func foreignDockerPortOwners(
        excluding projectId: UUID,
        dockerStatuses: [UUID: [DockerServiceStatus]],
        projects: [Project]
    ) -> [Int: String] {
        let names = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.name) })
        var result: [Int: String] = [:]
        for (id, services) in dockerStatuses where id != projectId {
            let projectName = names[id] ?? "another project"
            for service in services {
                for port in service.ports {
                    if result[port] == nil {
                        result[port] = "\(projectName) · \(service.name)"
                    }
                }
            }
        }
        return result
    }

    private static func dedupeRequirements(_ requirements: [ProjectPortRequirement]) -> [ProjectPortRequirement] {
        var byPort: [Int: ProjectPortRequirement] = [:]
        for requirement in requirements {
            if let existing = byPort[requirement.port] {
                // Prefer env-writable entries when two sources share a port.
                if requirement.isEnvWritable, !existing.isEnvWritable {
                    byPort[requirement.port] = requirement
                }
            } else {
                byPort[requirement.port] = requirement
            }
        }
        return Array(byPort.values).sorted { $0.port < $1.port }
    }
}
