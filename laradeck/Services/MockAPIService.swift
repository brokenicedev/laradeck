import AppKit
import Foundation
import MockAPIKit
import Observation
import UniformTypeIdentifiers

/// Runs the user's mock API servers: one HTTP listener per enabled server, saved in `mocks.json`.
@MainActor
@Observable
final class MockAPIService {
    /// One per process: ports can only be bound once, even if SwiftUI builds `AppState` twice.
    static let shared = MockAPIService()

    static let defaultPort = 3001

    private(set) var servers: [MockServer] = []
    private(set) var states: [UUID: HTTPServer.State] = [:]
    private(set) var logs: [UUID: [MockLogEntry]] = [:]
    /// Requests that matched no route since the log was last viewed, per server.
    private(set) var unmatchedCount: [UUID: Int] = [:]

    // MARK: Settings

    var autoStartEnabled: Bool { didSet { UserDefaults.standard.set(autoStartEnabled, forKey: Keys.autoStart) } }
    var logLimit: Int { didSet { UserDefaults.standard.set(logLimit, forKey: Keys.logLimit); trimLogs() } }

    private enum Keys {
        static let autoStart = "mockapi.autoStart"
        static let logLimit = "mockapi.logLimit"
    }

    @ObservationIgnored private var listeners: [UUID: HTTPServer] = [:]
    @ObservationIgnored private var engines: [UUID: MockEngine] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    private init() {
        let d = UserDefaults.standard
        autoStartEnabled = d.object(forKey: Keys.autoStart) as? Bool ?? true
        logLimit = d.object(forKey: Keys.logLimit) as? Int ?? 500
        load()
    }

    // MARK: Lifecycle

    /// Starts the servers marked "start with Laradeck". Safe to call more than once.
    func start() {
        guard !started else { return }
        started = true
        guard autoStartEnabled else { return }
        for server in servers where server.autoStart {
            startServer(server.id)
        }
    }

    func server(id: UUID) -> MockServer? { servers.first { $0.id == id } }

    func state(_ id: UUID) -> HTTPServer.State { states[id] ?? .stopped }

    func isRunning(_ id: UUID) -> Bool {
        if case .running = state(id) { return true }
        return false
    }

    var runningCount: Int { servers.filter { isRunning($0.id) }.count }

    func baseURL(for server: MockServer) -> String {
        let prefix = PathPattern.join(server.prefix)
        return "http://127.0.0.1:\(server.port)\(prefix == "/" ? "" : prefix)"
    }

    func startServer(_ id: UUID) {
        guard let server = server(id: id) else { return }
        let engine = engines[id] ?? MockEngine(server: server)
        engines[id] = engine
        let listener = listeners[id] ?? makeListener(id: id, engine: engine)
        listeners[id] = listener
        listener.cors = server.cors
        listener.start(port: UInt16(clamping: server.port))
    }

    func stopServer(_ id: UUID) {
        listeners[id]?.stop()
    }

    func toggle(_ id: UUID) {
        isRunning(id) ? stopServer(id) : startServer(id)
    }

    func stopAll() {
        listeners.values.forEach { $0.stop() }
    }

    private func makeListener(id: UUID, engine: MockEngine) -> HTTPServer {
        let listener = HTTPServer(label: "laradeck.mockapi.\(id.uuidString)") { [weak self] request in
            let result = await engine.handle(request)
            await self?.record(result.log, for: id)
            return result.response
        }
        listener.maxRequestBytes = 50 * 1024 * 1024
        listener.onStateChange = { [weak self] state in
            Task { @MainActor in self?.states[id] = state }
        }
        return listener
    }

    // MARK: Editing

    /// Adds a server (new or imported), picking a free port when its own is taken.
    @discardableResult
    func add(_ server: MockServer) -> MockServer {
        var server = server
        server.port = freePort(preferred: server.port)
        servers.append(server)
        scheduleSave()
        return server
    }

    func newServer() -> MockServer {
        var server = MockServer(name: uniqueName("Mock API"), port: Self.defaultPort)
        server.routes = [
            MockRoute(method: "GET", path: "hello", notes: "Example route", responses: [
                MockResponse(label: "Hello", status: 200,
                             headers: [MockHeader(name: "Content-Type", value: "application/json")],
                             body: "{\n    \"message\": \"Hello {{query.name}}\",\n    \"id\": \"{{uuid}}\"\n}",
                             isDefault: true),
            ]),
        ]
        return add(server)
    }

    /// Saves changes and pushes them to the running listener, restarting it when port or CORS changed.
    func update(_ server: MockServer) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        let old = servers[index]
        guard old != server else { return }
        servers[index] = server
        scheduleSave()
        if let engine = engines[server.id] {
            Task { await engine.update(server) }
        }
        if (old.port != server.port || old.cors != server.cors), case .running = state(server.id) {
            startServer(server.id)
        }
    }

    func delete(_ id: UUID) {
        listeners[id]?.stop()
        listeners[id] = nil
        engines[id] = nil
        logs[id] = nil
        states[id] = nil
        unmatchedCount[id] = nil
        servers.removeAll { $0.id == id }
        scheduleSave()
    }

    func duplicate(_ id: UUID) -> MockServer? {
        guard var copy = server(id: id) else { return nil }
        copy.id = UUID()
        copy.name = uniqueName(copy.name)
        copy.autoStart = false
        return add(copy)
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(servers.map(\.name))
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// The first port from `preferred` that no other mock uses and nothing listens on.
    func freePort(preferred: Int, excluding id: UUID? = nil) -> Int {
        let taken = Set(servers.filter { $0.id != id }.map(\.port))
        var port = max(1024, preferred)
        while taken.contains(port) || PortConflictService.isPortInUse(port) {
            port += 1
        }
        return port
    }

    // MARK: Import / export

    /// Imports an OpenAPI/Swagger spec, a Postman collection or a Laradeck mock file.
    func importFile(_ url: URL) throws -> MockImportResult {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        var result = try MockImporter.importFile(at: url, port: freePort(preferred: Self.defaultPort))
        result.server.name = uniqueName(result.server.name)
        result.server = add(result.server)
        return result
    }

    /// Whether a dropped file looks like something `importFile` understands (vs. a compose YAML).
    nonisolated static func looksLikeMockSource(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ["json", "yaml", "yml"].contains(ext),
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
        if ext == "json" { return true }
        return head.range(of: #"(?m)^(openapi|swagger)\s*:"#, options: .regularExpression) != nil
    }

    func exportServer(_ id: UUID) {
        guard let server = server(id: id), let data = try? MockImporter.export(server) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(server.name).laradeck-mock.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Log

    private func record(_ entry: MockLogEntry, for id: UUID) {
        var list = logs[id] ?? []
        list.insert(entry, at: 0)
        if list.count > logLimit { list.removeLast(list.count - logLimit) }
        logs[id] = list
        if !entry.matched { unmatchedCount[id, default: 0] += 1 }
    }

    func clearLog(_ id: UUID) {
        logs[id] = []
        unmatchedCount[id] = 0
    }

    func markLogSeen(_ id: UUID) {
        unmatchedCount[id] = 0
    }

    private func trimLogs() {
        for (id, list) in logs where list.count > logLimit {
            logs[id] = Array(list.prefix(logLimit))
        }
    }

    /// A route that answers exactly what an unmatched request asked for.
    func addRoute(from entry: MockLogEntry, to id: UUID) -> MockRoute? {
        guard var server = server(id: id) else { return nil }
        let prefix = PathPattern.join(server.prefix)
        var path = entry.path
        if prefix != "/", path.hasPrefix(prefix) { path = String(path.dropFirst(prefix.count)) }
        let route = MockRoute(
            method: entry.method == "HEAD" ? "GET" : entry.method,
            path: PathPattern.join(path).trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            responses: [MockResponse(label: "OK", status: 200,
                                     headers: [MockHeader(name: "Content-Type", value: "application/json")],
                                     body: "{}", isDefault: true)]
        )
        server.routes.append(route)
        update(server)
        return route
    }

    // MARK: Persistence

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Laradeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mocks.json")
    }

    private nonisolated struct File: Codable {
        var servers: [MockServer]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return }
        servers = file.servers
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            let file = File(servers: self.servers)
            let url = self.fileURL
            await Task.detached(priority: .utility) {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? encoder.encode(file) {
                    try? data.write(to: url, options: .atomic)
                }
            }.value
        }
    }

    /// Writes pending changes right away (used when the app quits).
    func flush() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(File(servers: servers)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
