import AppKit
import DBEngineKit
import Foundation
import Observation

/// Local PostgreSQL / MySQL / Redis servers run as per-user launchd agents (see DBEngineKit).
/// launchd owns the processes, so they keep running when Laradeck quits.
@MainActor
@Observable
final class DatabaseManager {
    nonisolated struct Row: Identifiable, Equatable, Sendable {
        let service: Service
        var status: ServiceStatus
        var id: UUID { service.id }
        var isRunning: Bool { status.isRunning }
    }

    /// Where a new service gets its binaries.
    nonisolated enum BinarySource: Hashable, Sendable {
        /// Homebrew formula, installed first if missing.
        case homebrew(String)
        /// A folder that contains `bin/<server>`.
        case folder(URL)
    }

    private(set) var rows: [Row] = []
    private(set) var busy: Set<UUID> = []
    /// Latest progress line per service (e.g. `brew install` output while switching binaries).
    private(set) var progress: [UUID: String] = [:]
    /// Databases inside each running PostgreSQL / MySQL server; missing = not checked yet.
    private(set) var databaseNames: [UUID: Set<String>] = [:]
    var error: String?

    var startOnLaunch: Bool {
        didSet { UserDefaults.standard.set(startOnLaunch, forKey: Self.startOnLaunchKey) }
    }

    let manager: ServiceManager
    private var refreshTask: Task<Void, Never>?
    private static let startOnLaunchKey = "startDatabasesOnLaunch"

    init(manager: ServiceManager = ServiceManager()) {
        self.manager = manager
        self.startOnLaunch = (UserDefaults.standard.object(forKey: Self.startOnLaunchKey) as? Bool) ?? true
        refreshTask = Task { [weak self] in
            if self?.startOnLaunch == true { await self?.startAutoStartServices() }
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    var isHomebrewInstalled: Bool { Homebrew.prefix != nil }
    var runningCount: Int { rows.filter(\.isRunning).count }

    func row(id: UUID) -> Row? { rows.first { $0.id == id } }

    // MARK: Status

    /// `launchctl print` per service is slow-ish, so it runs off the main thread.
    func refresh() async {
        let manager = manager
        let fresh = await Task.detached {
            ((try? manager.services()) ?? []).map { Row(service: $0, status: manager.status(of: $0)) }
        }.value
        if fresh != rows { rows = fresh }
        // A stopped server can't be asked; forget what it had so the UI shows "unknown".
        let running = Set(fresh.filter(\.isRunning).map(\.id))
        for id in databaseNames.keys where !running.contains(id) { databaseNames[id] = nil }
    }

    // MARK: Databases inside a server

    enum DatabaseCheck: Equatable {
        case exists
        case missing
        /// Server stopped or not asked yet.
        case unknown
    }

    func check(database name: String, in service: Service) -> DatabaseCheck {
        guard let names = databaseNames[service.id] else { return .unknown }
        return names.contains(name) ? .exists : .missing
    }

    /// Asks a running server for its databases (psql / mysql). Quietly does nothing when stopped.
    func loadDatabaseNames(_ service: Service) async {
        guard service.kind != .redis, row(id: service.id)?.isRunning == true else { return }
        let manager = manager
        if let names = try? await Task.detached(operation: { try manager.databaseNames(in: service) }).value {
            databaseNames[service.id] = Set(names)
        }
    }

    func createDatabase(_ name: String, in service: Service) {
        let manager = manager
        perform(service.id, then: { [weak self] in await self?.loadDatabaseNames(service) }) {
            try manager.createDatabase(name, in: service)
        }
    }

    private func startAutoStartServices() async {
        let manager = manager
        let failures = await Task.detached { await manager.startAutoStartServices() }.value
        if let (service, error) = failures.first {
            self.error = "\(service.name): \(error.localizedDescription)"
        }
        await refresh()
    }

    // MARK: Actions

    func toggle(_ row: Row) {
        if row.status == .stopped { start(row.service) } else { stop(row.service) }
    }

    func start(_ service: Service) {
        let manager = manager
        perform(service.id) { try await manager.start(service) }
    }

    func stop(_ service: Service) {
        let manager = manager
        perform(service.id) { try manager.stop(service) }
    }

    func delete(_ service: Service) {
        let manager = manager
        perform(service.id) { try manager.delete(service) }
    }

    func setAutoStart(_ service: Service, _ on: Bool) {
        do { try manager.setAutoStart(service, on) } catch { self.error = error.localizedDescription }
        Task { await refresh() }
    }

    func isHomebrew(_ service: Service) -> Bool { manager.isHomebrew(service) }

    // MARK: Network sharing

    /// Opens the server to the LAN through a password-protected user, or closes it again.
    /// Either way the server restarts if it was running.
    func setNetworkShare(_ service: Service, _ on: Bool) {
        let manager = manager
        perform(service.id) {
            if on { try await manager.enableNetworkShare(service) }
            else { try await manager.disableNetworkShare(service) }
        }
    }

    /// Connection URL colleagues paste into TablePlus & co.
    static func shareConnectionURL(_ service: Service, host: String) -> URL? {
        guard let share = service.networkShare else { return nil }
        return connectionURL(kind: service.kind, host: host, port: service.port, user: share.user,
                             password: share.password, database: nil, name: service.name)
    }

    /// Laravel `.env` lines for a colleague's project.
    static func shareEnv(_ service: Service, host: String) -> String? {
        guard let share = service.networkShare else { return nil }
        let connection = service.kind == .postgresql ? "pgsql" : "mysql"
        return """
        DB_CONNECTION=\(connection)
        DB_HOST=\(host)
        DB_PORT=\(service.port)
        DB_USERNAME=\(share.user)
        DB_PASSWORD=\(share.password)
        """
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Installs the matching Homebrew formula and points the service at it (data is kept).
    func switchToHomebrew(_ service: Service) {
        let manager = manager
        let id = service.id
        perform(id) {
            try await manager.switchToHomebrew(service) { line in
                Task { @MainActor [weak self] in self?.progress[id] = line }
            }
        }
    }

    /// Starts every stopped service in `services`, waiting until each accepts connections.
    /// Returns an error message per service that failed.
    func ensureRunning(_ services: [Service]) async -> [String] {
        await refresh()
        var failures: [String] = []
        for service in services where row(id: service.id)?.isRunning != true {
            busy.insert(service.id)
            let manager = manager
            do {
                try await Task.detached { try await manager.start(service) }.value
            } catch {
                failures.append("\(service.name): \(error.localizedDescription)")
            }
            busy.remove(service.id)
        }
        await refresh()
        return failures
    }

    /// Runs blocking DBEngineKit work off the main thread with a busy spinner on the row.
    private func perform(_ id: UUID, then: (() async -> Void)? = nil,
                         _ work: @escaping @Sendable () async throws -> Void) {
        busy.insert(id)
        error = nil
        Task {
            do {
                try await Task.detached { try await work() }.value
            } catch {
                self.error = error.localizedDescription
            }
            busy.remove(id)
            progress[id] = nil
            await refresh()
            await then?()
        }
    }

    // MARK: Create

    func suggestedPort(for kind: EngineKind) -> Int { manager.suggestedPort(for: kind) }

    func installedBinaries(for kind: EngineKind) -> [InstalledBinaries] { BinaryLocator.installed(kind) }

    @discardableResult
    func create(kind: EngineKind, name: String, source: BinarySource, port: Int,
                autoStart: Bool, startNow: Bool,
                progress: @escaping @Sendable (String) -> Void) async throws -> Service {
        let manager = manager
        let name: String? = name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name
        let creation = Task.detached { () async throws -> Service in
            switch source {
            case let .homebrew(formula):
                return try await manager.create(kind: kind, name: name, formula: formula, port: port,
                                                autoStart: autoStart, progress: progress)
            case let .folder(url):
                progress("Initializing database…")
                return try manager.create(kind: kind, name: name, version: url.lastPathComponent,
                                          binaries: url, port: port, autoStart: autoStart)
            }
        }
        // Detached tasks don't inherit cancellation; forward it so the sheet can stop `brew install`.
        let service = try await withTaskCancellationHandler {
            try await creation.value
        } onCancel: {
            creation.cancel()
        }
        await refresh()
        if startNow {
            progress("Starting…")
            busy.insert(service.id)
            defer { busy.remove(service.id) }
            try await Task.detached { try await manager.start(service) }.value
            await refresh()
        }
        return service
    }

    // MARK: Helpers

    func copyURL(_ service: Service) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(service.connectionURL, forType: .string)
    }

    func revealData(_ service: Service) {
        NSWorkspace.shared.activateFileViewerSelecting([service.dataURL])
    }

    func logFile(_ service: Service) -> URL { service.kind.logFile(service) }

    func openLog(_ service: Service) {
        let log = logFile(service)
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.open(log)
        } else {
            error = "No log yet for \(service.name)"
        }
    }

    static func tablePlusURL() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.tinyapp.TablePlus") {
            return url
        }
        let candidates = ["/Applications/TablePlus.app", "/Applications/Setapp/TablePlus.app",
                          "~/Applications/TablePlus.app"]
        return candidates.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// TablePlus buttons are only shown when it's installed.
    static var hasTablePlus: Bool { tablePlusURL() != nil }

    /// TablePlus URL for one database inside a server (`…/<database>?name=…`).
    static func connectionURL(_ service: Service, database: String?) -> URL? {
        connectionURL(kind: service.kind, port: service.port, user: service.kind.defaultUser,
                      password: nil, database: database, name: service.name)
    }

    static func connectionURL(kind: EngineKind, host: String = "127.0.0.1", port: Int, user: String?,
                              password: String?, database: String?, name: String) -> URL? {
        var c = URLComponents()
        c.scheme = kind == .postgresql ? "postgresql" : kind.rawValue
        c.host = host
        c.port = port
        c.user = user
        c.password = password.flatMap { $0.isEmpty ? nil : $0 }
        if let database, kind != .redis { c.path = "/" + database }
        c.queryItems = [URLQueryItem(name: "name", value: name)]
        return c.url
    }

    /// Opens a connection URL in TablePlus (or its website when it isn't installed).
    static func openInTablePlus(_ url: URL) {
        guard let app = tablePlusURL() else {
            NSWorkspace.shared.open(URL(string: "https://tableplus.com")!)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)
    }

    /// Opens the service in TablePlus via its URL scheme, starting the server first if needed.
    func openInTablePlus(_ service: Service, database: String? = nil) {
        guard let app = Self.tablePlusURL() else {
            NSWorkspace.shared.open(URL(string: "https://tableplus.com")!)
            return
        }
        guard let url = database.flatMap({ Self.connectionURL(service, database: $0) })
                ?? URL(string: service.connectionURL) else { return }
        let manager = manager
        perform(service.id) {
            if !manager.status(of: service).isRunning { try await manager.start(service) }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)
        }
    }

    /// psql / mysql / redis-cli connected to the service, in the user's terminal.
    func openShell(_ service: Service, terminal: TerminalApp) {
        let bin = service.binaryURL.path
        let client: String
        switch service.kind {
        case .postgresql: client = "psql' -h 127.0.0.1 -p \(service.port) -U postgres"
        case .mysql: client = "mysql' -h 127.0.0.1 -P \(service.port) -u root"
        case .redis: client = "redis-cli' -p \(service.port)"
        }
        TerminalLauncher.runCommand(terminal, "'\(bin.replacingOccurrences(of: "'", with: "'\\''"))/\(client)")
    }
}
