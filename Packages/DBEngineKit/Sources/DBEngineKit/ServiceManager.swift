import Foundation

public enum ServiceError: LocalizedError {
    case notFound(String)
    case ambiguous(String)
    case portInUse(Int)
    case missingBinary(URL)
    case startFailed(String, log: String)

    public var errorDescription: String? {
        switch self {
        case let .notFound(q): "No service matches '\(q)'"
        case let .ambiguous(q): "More than one service matches '\(q)'; use the ID"
        case let .portInUse(p): "Port \(p) is being used by another application. Run `lsof -nP -iTCP:\(p) -sTCP:LISTEN` to see which one, or pick another port."
        case let .missingBinary(u): "Server binary not found at \(u.path)"
        case let .startFailed(n, log): "\(n) did not start. Last log lines:\n\(log)"
        }
    }
}

public enum ServiceStatus: Equatable, Sendable {
    case stopped
    case running(pid: Int32)
    case starting(String)

    public var isRunning: Bool { if case .running = self { true } else { false } }

    public var description: String {
        switch self {
        case .stopped: "stopped"
        case let .running(pid): "running (pid \(pid))"
        case let .starting(s): s
        }
    }
}

/// High-level operations: create / start / stop / delete a database service.
public final class ServiceManager: @unchecked Sendable {
    public let paths: Paths
    public let store: ServiceStore

    public init(paths: Paths = Paths()) {
        self.paths = paths
        self.store = ServiceStore(paths: paths)
    }

    public func services() throws -> [Service] { try store.load() }

    public func find(_ query: String) throws -> Service {
        let all = try store.load()
        if let exact = all.first(where: { $0.id.uuidString.caseInsensitiveCompare(query) == .orderedSame }) {
            return exact
        }
        let matches = all.filter {
            $0.name.caseInsensitiveCompare(query) == .orderedSame
                || $0.id.uuidString.lowercased().hasPrefix(query.lowercased())
        }
        guard !matches.isEmpty else { throw ServiceError.notFound(query) }
        guard matches.count == 1 else { throw ServiceError.ambiguous(query) }
        return matches[0]
    }

    public func label(for s: Service) -> String { s.launchdLabel(prefix: paths.label) }

    public func plistURL(for s: Service) -> URL {
        s.dataURL.appendingPathComponent("\(label(for: s)).plist")
    }

    public func status(of s: Service) -> ServiceStatus {
        switch Launchd.state(label: label(for: s)) {
        case .notLoaded: .stopped
        case let .running(pid): .running(pid: pid)
        case let .loaded(state): .starting(state)
        }
    }

    // MARK: Create

    /// Registers a new service using already-unpacked binaries and initialises its data folder.
    @discardableResult
    public func create(kind: EngineKind, name: String? = nil, version: String,
                       binaries: URL, port: Int? = nil, autoStart: Bool = false) throws -> Service {
        let server = binaries.appendingPathComponent("bin").appendingPathComponent(kind.serverBinary)
        guard FileManager.default.isExecutableFile(atPath: server.path) else {
            throw ServiceError.missingBinary(server)
        }
        let id = UUID()
        let existing = try store.load()
        let port = port ?? nextFreePort(kind.defaultPort, taken: Set(existing.map(\.port)))
        let service = Service(id: id,
                              name: name ?? "\(kind.displayName) \(version)",
                              kind: kind, version: version,
                              binariesPath: binaries.path,
                              dataPath: paths.dataPath(for: kind, id: id).path,
                              port: port, autoStart: autoStart)

        try FileManager.default.createDirectory(at: service.dataURL, withIntermediateDirectories: true)
        do {
            for cmd in kind.initCommands(service) {
                try Shell.run(cmd, cwd: service.dataURL, environment: kind.environment)
            }
        } catch {
            try? FileManager.default.removeItem(at: service.dataURL)
            throw error
        }
        try store.update { $0.append(service) }
        return service
    }

    /// Installs the Homebrew formula if needed, then creates the service.
    @discardableResult
    public func create(kind: EngineKind, name: String? = nil, formula: String, port: Int? = nil,
                       autoStart: Bool = false,
                       progress: (@Sendable (String) -> Void)? = nil) async throws -> Service {
        let bin = try await homebrewBinaries(formula: formula, kind: kind, progress: progress)
        progress?("Initializing database…")
        return try create(kind: kind, name: name, version: bin.version, binaries: bin.url,
                          port: port, autoStart: autoStart)
    }

    func homebrewBinaries(formula: String, kind: EngineKind,
                          progress: (@Sendable (String) -> Void)?) async throws -> InstalledBinaries {
        if let b = Homebrew.installedBinaries(formula: formula, kind: kind) { return b }
        progress?("brew install \(formula)…")
        try await Homebrew.install(formula, output: progress)
        guard let b = Homebrew.installedBinaries(formula: formula, kind: kind) else {
            throw HomebrewError.installFailed(formula, output: "bin/\(kind.serverBinary) not found after install")
        }
        return b
    }

    public func isHomebrew(_ s: Service) -> Bool {
        guard let prefix = Homebrew.prefix else { return false }
        return s.binariesPath.hasPrefix(prefix.appendingPathComponent("opt").path + "/")
    }

    /// Points an existing service at other binaries, keeping its data.
    /// PostgreSQL data only works with the same major version, so that is checked.
    public func switchBinaries(_ s: Service, to b: InstalledBinaries) async throws {
        if s.kind == .postgresql {
            let pgVersion = s.kind.dbFilesDir(s).appendingPathComponent("PG_VERSION")
            let dataMajor = (try? String(contentsOf: pgVersion, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let newMajor = b.version.split(separator: ".").first.map(String.init)
            if let dataMajor, dataMajor != newMajor {
                throw HomebrewError.incompatible(
                    "\(s.name) holds PostgreSQL \(dataMajor) data; it needs postgresql@\(dataMajor), not \(b.version).")
            }
        }
        let wasRunning = status(of: s).isRunning
        if wasRunning { try stop(s) }
        let updated = try store.update { list -> Service? in
            guard let i = list.firstIndex(where: { $0.id == s.id }) else { return nil }
            list[i].binariesPath = b.url.path
            list[i].version = b.version
            return list[i]
        }
        if wasRunning, let updated { try await start(updated) }
    }

    /// Installs the matching Homebrew formula (same major version) and switches the service to it.
    public func switchToHomebrew(_ s: Service, progress: (@Sendable (String) -> Void)? = nil) async throws {
        let formula = Homebrew.formula(for: s.kind, version: s.version)
        let b = try await homebrewBinaries(formula: formula, kind: s.kind, progress: progress)
        try await switchBinaries(s, to: b)
    }

    /// First port at or above the engine default that no service uses and nothing listens on.
    public func suggestedPort(for kind: EngineKind) -> Int {
        let taken = Set(((try? store.load()) ?? []).map(\.port))
        return nextFreePort(kind.defaultPort, taken: taken)
    }

    private func nextFreePort(_ start: Int, taken: Set<Int>) -> Int {
        var p = start
        while taken.contains(p) || Port.isListening(p) { p += 1 }
        return p
    }

    // MARK: Start / stop

    public func start(_ s: Service, timeout: TimeInterval = 30) async throws {
        if status(of: s).isRunning { return }
        if Port.isListening(s.port) { throw ServiceError.portInUse(s.port) }

        let plist = try Launchd.plist(label: label(for: s),
                                      arguments: s.kind.serverArguments(s),
                                      workingDirectory: s.dataURL,
                                      logFile: s.kind.logFile(s),
                                      environment: s.kind.environment,
                                      fileLimit: s.kind == .redis ? nil : 10240)
        try plist.write(to: plistURL(for: s), options: .atomic)

        // A stale job (e.g. crashed and gave up) must be removed before bootstrapping again.
        try? Launchd.bootout(label: label(for: s))
        try Launchd.bootstrap(plist: plistURL(for: s))

        guard await Port.waitUntilListening(s.port, timeout: timeout) else {
            let log = tail(s.kind.logFile(s), lines: 15)
            try? Launchd.bootout(label: label(for: s))
            throw ServiceError.startFailed(s.name, log: log)
        }
    }

    public func stop(_ s: Service) throws {
        try Launchd.bootout(label: label(for: s))
    }

    /// Starts every service marked autoStart. Launchd jobs loaded with
    /// `bootstrap` don't survive logout, so the app calls this at launch
    /// (DBngin does the same with its "AutoStartup" flag + login item).
    public func startAutoStartServices() async -> [(Service, Error)] {
        var failures: [(Service, Error)] = []
        for s in (try? store.load()) ?? [] where s.autoStart {
            do { try await start(s) } catch { failures.append((s, error)) }
        }
        return failures
    }

    // MARK: Delete

    public func delete(_ s: Service, keepData: Bool = false) throws {
        try? stop(s)
        try store.update { $0.removeAll { $0.id == s.id } }
        if !keepData, FileManager.default.fileExists(atPath: s.dataPath) {
            try FileManager.default.trashItem(at: s.dataURL, resultingItemURL: nil)
        }
    }

    // MARK: Databases inside a server (PostgreSQL / MySQL)

    /// Names of the databases on a running server, via its own client (psql / mysql).
    /// Redis has numbered databases only, so it returns [].
    public func databaseNames(in s: Service) throws -> [String] {
        guard let command = s.kind.clientCommand(s, sql: s.kind.listDatabasesSQL) else { return [] }
        let output = try Shell.run(command, environment: s.kind.environment).output
        return output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("mysql:") && !$0.hasPrefix("Warning") }
    }

    /// `CREATE DATABASE` with the engine's quoting (UTF-8 for MySQL, like Laravel's defaults).
    public func createDatabase(_ name: String, in s: Service) throws {
        guard let sql = s.kind.createDatabaseSQL(name),
              let command = s.kind.clientCommand(s, sql: sql) else { return }
        try Shell.run(command, environment: s.kind.environment)
    }

    // MARK: Network sharing

    /// Opens the server to the LAN for a password-protected share user. The server is
    /// started if needed (the user is created with its own client), restarted so it listens on
    /// every interface, and stopped again if it wasn't running before.
    @discardableResult
    public func enableNetworkShare(_ s: Service) async throws -> Service {
        guard s.kind.supportsNetworkShare else { return s }
        let share = s.networkShare ?? NetworkShare.generate()
        let wasRunning = status(of: s).isRunning
        if !wasRunning { try await start(s) }

        for sql in s.kind.shareUserSQL(share) {
            if let command = s.kind.clientCommand(s, sql: sql) {
                try Shell.run(command, environment: s.kind.environment)
            }
        }
        if let hba = s.kind.hbaFile(s) {
            let text = (try? String(contentsOf: hba, encoding: .utf8)) ?? ""
            try NetworkShare.addingShareBlock(to: text, user: share.user)
                .write(to: hba, atomically: true, encoding: .utf8)
        }
        let updated = try saveShare(share, for: s)
        try stop(s)
        if wasRunning { try await start(updated) }
        return updated
    }

    /// Back to localhost only: drops the share user and its pg_hba rule.
    @discardableResult
    public func disableNetworkShare(_ s: Service) async throws -> Service {
        guard let share = s.networkShare else { return s }
        let wasRunning = status(of: s).isRunning
        if wasRunning {
            if let release = s.kind.releaseShareUserSQL(share) {
                for database in try databaseNames(in: s) {
                    if let command = s.kind.clientCommand(s, sql: release, database: database) {
                        try Shell.run(command, environment: s.kind.environment)
                    }
                }
            }
            if let terminate = s.kind.terminateShareSessionsSQL(share),
               let command = s.kind.clientCommand(s, sql: terminate) {
                try Shell.run(command, environment: s.kind.environment)
            }
            for sql in s.kind.dropShareUserSQL(share) {
                if let command = s.kind.clientCommand(s, sql: sql) {
                    try Shell.run(command, environment: s.kind.environment)
                }
            }
        }
        if let hba = s.kind.hbaFile(s), let text = try? String(contentsOf: hba, encoding: .utf8) {
            try NetworkShare.removingShareBlock(from: text)
                .write(to: hba, atomically: true, encoding: .utf8)
        }
        let updated = try saveShare(nil, for: s)
        if wasRunning {
            try stop(s)
            try await start(updated)
        }
        return updated
    }

    private func saveShare(_ share: NetworkShare?, for s: Service) throws -> Service {
        let updated = try store.update { list -> Service? in
            guard let i = list.firstIndex(where: { $0.id == s.id }) else { return nil }
            list[i].networkShare = share
            return list[i]
        }
        guard let updated else { throw ServiceError.notFound(s.id.uuidString) }
        return updated
    }

    public func setAutoStart(_ s: Service, _ on: Bool) throws {
        try store.update { list in
            if let i = list.firstIndex(where: { $0.id == s.id }) { list[i].autoStart = on }
        }
    }

    // MARK: Helpers

    public func tail(_ file: URL, lines: Int) -> String {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return "(no log)" }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(lines).joined(separator: "\n")
    }
}
