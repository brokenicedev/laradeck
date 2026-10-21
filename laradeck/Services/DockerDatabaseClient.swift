import DBEngineKit
import Foundation

/// Read-only helpers for database containers (DockerDatabase): list / create databases with
/// the client inside the container, and tail its logs. They never touch the Compose output
/// panel or send notifications, unlike `DockerManager`'s user-facing commands.
extension DockerManager {
    /// Databases in the container, using its own credentials (POSTGRES_USER, MYSQL_ROOT_PASSWORD…).
    func databaseNames(in database: DockerDatabase) async -> [String]? {
        guard let script = Self.clientScript(for: database.kind) else { return [] }
        let sql = database.kind == .postgresql
            ? "SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY datname;"
            : "SHOW DATABASES;"
        let result = await composeQuery(
            ["exec", "-T", database.service, "sh", "-c", script],
            projectPath: database.projectPath, stdin: sql
        )
        guard result.success else { return nil }
        return result.output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func createDatabase(_ name: String, in database: DockerDatabase) async -> DockerCommandResult {
        guard let script = Self.clientScript(for: database.kind) else {
            return DockerCommandResult(success: false, output: "Redis has no named databases.")
        }
        let sql: String
        switch database.kind {
        case .postgresql:
            sql = "CREATE DATABASE \"\(name.replacingOccurrences(of: "\"", with: "\"\""))\";"
        case .mysql:
            sql = "CREATE DATABASE `\(name.replacingOccurrences(of: "`", with: "``"))` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
        case .redis:
            return DockerCommandResult(success: false, output: "")
        }
        let result = await composeQuery(
            ["exec", "-T", database.service, "sh", "-c", script],
            projectPath: database.projectPath, stdin: sql, mergeStderr: true
        )
        return DockerCommandResult(success: result.success, output: result.output)
    }

    func logTail(of database: DockerDatabase, lines: Int = 40) async -> String {
        let result = await composeQuery(
            ["logs", "--no-color", "--no-log-prefix", "--tail", String(lines), database.service],
            projectPath: database.projectPath, mergeStderr: true
        )
        return result.output
    }

    /// Shell snippet that runs SQL from stdin as the container's superuser, printing bare rows.
    /// SQL goes through stdin so names never need shell quoting.
    private static func clientScript(for kind: EngineKind) -> String? {
        switch kind {
        case .postgresql:
            return #"psql -X -q -t -A -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d postgres"#
        case .mysql:
            // MariaDB images ship `mariadb` instead of `mysql`. MYSQL_PWD avoids a password prompt.
            return #"c=$(command -v mysql || command -v mariadb); MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-$MARIADB_ROOT_PASSWORD}" "$c" -uroot --batch --skip-column-names"#
        case .redis:
            return nil
        }
    }

    /// `docker compose <args>` in the project folder; stdout only unless `mergeStderr`.
    func composeQuery(_ arguments: [String], projectPath: String, stdin: String? = nil,
                      mergeStderr: Bool = false) async -> (success: Bool, output: String) {
        guard let docker = await RuntimeResolver.shared.resolvePath(for: "docker") else { return (false, "") }
        var environment = await RuntimeResolver.shared.loginShellEnvironment()
        if environment.isEmpty { environment = ProcessInfo.processInfo.environment }
        environment["NO_COLOR"] = "1"
        environment["DOCKER_CLI_HINTS"] = "false"

        let env = environment
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: docker)
            process.arguments = ["compose"] + arguments
            process.currentDirectoryURL = URL(fileURLWithPath: projectPath, isDirectory: true)
            process.environment = env
            let out = Pipe()
            process.standardOutput = out
            process.standardError = mergeStderr ? out : FileHandle.nullDevice
            let input = Pipe()
            process.standardInput = stdin == nil ? FileHandle.nullDevice : input
            do { try process.run() } catch { return (false, error.localizedDescription) }
            if let stdin {
                input.fileHandleForWriting.write(Data(stdin.utf8))
                try? input.fileHandleForWriting.close()
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self))
        }.value
    }
}
