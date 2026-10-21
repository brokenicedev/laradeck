import DBEngineKit
import Foundation

/// A local database server a native project's `.env` points at.
nonisolated struct ProjectDatabaseRequirement: Equatable, Hashable, Sendable {
    var kind: EngineKind
    var port: Int
    /// `.env` key the port came from (or would come from), e.g. `DB_PORT`.
    var envKey: String
    /// `DB_DATABASE` for PostgreSQL / MySQL (Laravel's default is `laravel`); nil for Redis.
    var database: String? = nil
}

/// Maps a project's `.env` to the Laradeck database services it needs.
nonisolated enum ProjectDatabaseLink {
    /// Requirements for a project, or none when its database runs elsewhere
    /// (a container, a remote host, SQLite).
    static func requirements(for project: Project) -> [ProjectDatabaseRequirement] {
        let inDocker = project.environment == .sail || project.hasDockerCompose
        return requirements(env: LaravelDetector.readEnvFile(at: project.path), inDocker: inDocker)
    }

    /// `inDocker`: the app runs in a container (Sail / Compose). Then only hosts that point
    /// back at the Mac (`host.docker.internal`) count; `mysql`, `pgsql`… are containers.
    static func requirements(env: [String: String], inDocker: Bool = false) -> [ProjectDatabaseRequirement] {
        let isLocal: (String?) -> Bool = { inDocker ? isDockerHost($0) : isLocalHost($0) }

        var result: [ProjectDatabaseRequirement] = []

        if let connection = env["DB_CONNECTION"]?.lowercased(),
           let kind = engine(forConnection: connection),
           isLocal(env["DB_HOST"]) {
            let port = Int(env["DB_PORT"] ?? "") ?? kind.defaultPort
            let database = env["DB_DATABASE"].flatMap { $0.isEmpty ? nil : $0 } ?? "laravel"
            result.append(ProjectDatabaseRequirement(kind: kind, port: port, envKey: "DB_PORT", database: database))
        }

        let redisKeys = ["CACHE_STORE", "CACHE_DRIVER", "QUEUE_CONNECTION", "SESSION_DRIVER", "BROADCAST_CONNECTION"]
        let usesRedis = redisKeys.contains { env[$0]?.lowercased() == "redis" }
        if usesRedis, isLocal(env["REDIS_HOST"]) {
            let port = Int(env["REDIS_PORT"] ?? "") ?? EngineKind.redis.defaultPort
            result.append(ProjectDatabaseRequirement(kind: .redis, port: port, envKey: "REDIS_PORT"))
        }
        return result
    }

    /// The service that satisfies a requirement: same engine, same port.
    static func service(for requirement: ProjectDatabaseRequirement, in services: [Service]) -> Service? {
        services.first { $0.kind == requirement.kind && $0.port == requirement.port }
    }

    static func engine(forConnection connection: String) -> EngineKind? {
        switch connection {
        case "pgsql", "postgres", "postgresql": return .postgresql
        case "mysql", "mariadb": return .mysql
        default: return nil
        }
    }

    /// Names a container uses to reach the Mac (Docker Desktop, OrbStack).
    static let dockerHostNames: Set<String> = [
        "host.docker.internal", "gateway.docker.internal", "docker.for.mac.host.internal",
        "docker.for.mac.localhost", "host.orb.internal",
    ]

    /// Empty host means Laravel's default, which is 127.0.0.1.
    static func isLocalHost(_ host: String?) -> Bool {
        guard let host = normalized(host) else { return true }
        return ["127.0.0.1", "localhost", "::1"].contains(host) || dockerHostNames.contains(host)
    }

    /// From inside a container an empty host or 127.0.0.1 is the container itself, not the Mac.
    static func isDockerHost(_ host: String?) -> Bool {
        guard let host = normalized(host) else { return false }
        return dockerHostNames.contains(host)
    }

    private static func normalized(_ host: String?) -> String? {
        guard let host = host?.trimmingCharacters(in: .whitespaces).lowercased(), !host.isEmpty else { return nil }
        return host
    }
}

/// A database server running in a project's Docker Compose stack (e.g. Sail's `mysql`).
nonisolated struct DockerDatabase: Identifiable, Equatable, Sendable {
    let projectId: UUID
    let projectName: String
    let projectPath: String
    /// Compose service name.
    let service: String
    let kind: EngineKind
    let isRunning: Bool
    /// First port published on the Mac, if any.
    let hostPort: Int?

    var id: String { "\(projectId.uuidString)/\(service)" }

    /// Engine from a Compose service name: Sail uses mysql, mariadb, pgsql, redis, valkey.
    static func engine(forService name: String) -> EngineKind? {
        let n = name.lowercased()
        if n.contains("pgsql") || n.contains("postgres") { return .postgresql }
        if n.contains("mysql") || n.contains("mariadb") { return .mysql }
        if n.contains("redis") || n.contains("valkey") { return .redis }
        return nil
    }

    static func list(projects: [Project], statuses: [UUID: [DockerServiceStatus]]) -> [DockerDatabase] {
        projects.flatMap { project -> [DockerDatabase] in
            (statuses[project.id] ?? []).compactMap { status in
                guard let kind = engine(forService: status.name) else { return nil }
                return DockerDatabase(projectId: project.id, projectName: project.name, projectPath: project.path,
                                      service: status.name, kind: kind, isRunning: status.isRunning,
                                      hostPort: status.ports.first)
            }
        }
    }
}
