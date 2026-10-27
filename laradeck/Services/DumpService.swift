import AppKit
import DumpKit
import Observation
import SwiftUI

/// Where a dump lands: a project's own stream, or the bucket for dumps no project claims.
enum DumpTarget: Hashable, Codable {
    case project(UUID)
    case unassigned

    var key: String {
        switch self {
        case .project(let id): return id.uuidString
        case .unassigned: return "unassigned"
        }
    }

    init?(key: String) {
        if key == "unassigned" { self = .unassigned; return }
        guard let id = UUID(uuidString: key) else { return nil }
        self = .project(id)
    }
}

/// One project's dump stream plus its view state (search, color filter, unread count).
@MainActor
@Observable
final class DumpSession: Identifiable {
    let target: DumpTarget
    let store = DumpStore()
    var searchText = ""
    var colorFilter: Set<String> = []
    /// Bumped to move keyboard focus to the search field.
    var searchFocusRequest = 0
    /// Rows received while nobody was looking at this stream.
    var unreadCount = 0
    /// Of those, how many were exceptions or red-flagged messages.
    var unreadErrorCount = 0

    var id: DumpTarget { target }

    init(target: DumpTarget) {
        self.target = target
    }

    struct DisplayItem: Identifiable {
        var entry: DumpEntry
        var count: Int
        var id: UUID { entry.id }
    }

    func visibleItems(groupDuplicates: Bool) -> [DisplayItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = store.currentScreen.entries.filter { entry in
            if !colorFilter.isEmpty && !colorFilter.contains(entry.color ?? "") { return false }
            if !query.isEmpty && !entry.searchText.contains(query) { return false }
            return true
        }
        guard groupDuplicates else { return filtered.map { DisplayItem(entry: $0, count: 1) } }
        var items: [DisplayItem] = []
        for entry in filtered {
            if let last = items.last, last.entry.groupingKey == entry.groupingKey, entry.lockName == nil {
                items[items.count - 1].count += 1
            } else {
                items.append(DisplayItem(entry: entry, count: 1))
            }
        }
        return items
    }
}

/// Runs the dump servers (main protocol on 23517, `ds()` on 9191) and splits what arrives per project.
@MainActor
@Observable
final class DumpService {
    /// One per process: the ports can only be bound once, even if SwiftUI builds `AppState` twice.
    static let shared = DumpService()

    static let defaultPort = 23517
    static let defaultDsPort = 9191
    /// Default app root inside Laravel Sail containers.
    static let containerAppRoot = "/var/www/html"

    private(set) var sessions: [DumpTarget: DumpSession] = [:]
    private(set) var serverState: HTTPServer.State = .stopped
    private(set) var dsServerState: HTTPServer.State = .stopped

    /// Stream shown in the Dumps window (nil until one is picked).
    var windowTarget: DumpTarget?
    /// Whether the Dumps window is open.
    var isWindowOpen = false
    /// Streams currently on screen (inline or detached); they don't collect unread counts.
    private(set) var visibleTargets: [DumpTarget: Int] = [:]

    // MARK: Settings

    var enabled: Bool { didSet { save(Keys.enabled, enabled); restartServers() } }
    var port: Int { didSet { save(Keys.port, port); restartServer() } }
    var dsEnabled: Bool { didSet { save(Keys.dsEnabled, dsEnabled); restartDsServer() } }
    var dsPort: Int { didSet { save(Keys.dsPort, dsPort); restartDsServer() } }
    var scrollOnLog: Bool { didSet { save(Keys.scrollOnLog, scrollOnLog) } }
    var historyLimit: Int {
        didSet { save(Keys.historyLimit, historyLimit); sessions.values.forEach { $0.store.historyLimit = historyLimit } }
    }
    var groupDuplicates: Bool { didSet { save(Keys.groupDuplicates, groupDuplicates) } }
    var compactUI: Bool { didSet { save(Keys.compactUI, compactUI) } }
    var labelledColors: Bool { didSet { save(Keys.labelledColors, labelledColors) } }
    var showTimestamp: Bool { didSet { save(Keys.showTimestamp, showTimestamp) } }
    var showFilename: Bool { didSet { save(Keys.showFilename, showFilename) } }
    var showColorIndicator: Bool { didSet { save(Keys.showColorIndicator, showColorIndicator) } }
    var showLabels: Bool { didSet { save(Keys.showLabels, showLabels) } }
    var notifyOnPause: Bool { didSet { save(Keys.notifyOnPause, notifyOnPause) } }
    var editor: Editor { didSet { save(Keys.editor, editor.rawValue) } }
    var customEditorURL: String { didSet { save(Keys.customEditorURL, customEditorURL) } }

    // MARK: Hooks set by AppState

    @ObservationIgnored var projectsProvider: () -> [Project] = { [] }
    @ObservationIgnored var composeRunning: (UUID) -> Bool = { _ in false }
    @ObservationIgnored var notify: (_ title: String, _ body: String) -> Void = { _, _ in }

    @ObservationIgnored private var router: DumpRouter!
    @ObservationIgnored private var server: HTTPServer!
    @ObservationIgnored private var dsServer: HTTPServer!
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    /// Saved streams not opened yet in this run, restored on first use.
    @ObservationIgnored private var pendingSnapshots: [String: JSONValue] = [:]

    private enum Keys {
        static let enabled = "dumps.enabled"
        static let port = "dumps.port"
        static let dsEnabled = "dumps.dsEnabled"
        static let dsPort = "dumps.dsPort"
        static let scrollOnLog = "dumps.scrollOnLog"
        static let historyLimit = "dumps.historyLimit"
        static let groupDuplicates = "dumps.groupDuplicates"
        static let compactUI = "dumps.compactUI"
        static let labelledColors = "dumps.labelledColors"
        static let showTimestamp = "dumps.showTimestamp"
        static let showFilename = "dumps.showFilename"
        static let showColorIndicator = "dumps.showColorIndicator"
        static let showLabels = "dumps.showLabels"
        static let notifyOnPause = "dumps.notifyOnPause"
        static let editor = "dumps.editor"
        static let customEditorURL = "dumps.customEditorURL"
    }

    private init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: Keys.enabled) as? Bool ?? true
        port = d.object(forKey: Keys.port) as? Int ?? Self.defaultPort
        dsEnabled = d.object(forKey: Keys.dsEnabled) as? Bool ?? true
        dsPort = d.object(forKey: Keys.dsPort) as? Int ?? Self.defaultDsPort
        scrollOnLog = d.object(forKey: Keys.scrollOnLog) as? Bool ?? true
        historyLimit = d.object(forKey: Keys.historyLimit) as? Int ?? 1000
        groupDuplicates = d.object(forKey: Keys.groupDuplicates) as? Bool ?? true
        compactUI = d.object(forKey: Keys.compactUI) as? Bool ?? false
        labelledColors = d.object(forKey: Keys.labelledColors) as? Bool ?? false
        showTimestamp = d.object(forKey: Keys.showTimestamp) as? Bool ?? true
        showFilename = d.object(forKey: Keys.showFilename) as? Bool ?? true
        showColorIndicator = d.object(forKey: Keys.showColorIndicator) as? Bool ?? true
        showLabels = d.object(forKey: Keys.showLabels) as? Bool ?? true
        notifyOnPause = d.object(forKey: Keys.notifyOnPause) as? Bool ?? true
        editor = Editor(rawValue: d.string(forKey: Keys.editor) ?? "") ?? .vscode
        customEditorURL = d.string(forKey: Keys.customEditorURL) ?? ""

        router = DumpRouter(
            storeFor: { [unowned self] hint in self.session(for: self.target(for: hint)).store },
            allStores: { [unowned self] in self.sessions.values.map(\.store) }
        )
        router.themeProvider = { ThemeStore.shared.theme.isDark ? "dark" : "light" }
        server = HTTPServer { [router] request in
            await MainActor.run { router!.handle(request) }
        }
        server.onStateChange = { [weak self] state in
            Task { @MainActor in self?.serverState = state }
        }
        dsServer = HTTPServer { [router] request in
            await MainActor.run { router!.handle(request) }
        }
        dsServer.onStateChange = { [weak self] state in
            Task { @MainActor in self?.dsServerState = state }
        }

        loadSnapshots()
    }

    // MARK: Servers

    func start() {
        guard !started else { return }
        started = true
        restartServers()
    }

    func restartServers() {
        restartServer()
        restartDsServer()
    }

    func restartServer() {
        guard started else { return }
        if enabled {
            server.start(port: UInt16(clamping: port))
        } else {
            server.stop()
        }
    }

    func restartDsServer() {
        guard started else { return }
        if enabled && dsEnabled && dsPort != port {
            dsServer.start(port: UInt16(clamping: dsPort))
        } else {
            // Same port as the main server: it already answers /api/dumps.
            dsServer.stop()
        }
    }

    // MARK: Sessions

    /// The session for a target, created (and restored from disk) on first use.
    func session(for target: DumpTarget) -> DumpSession {
        if let existing = sessions[target] { return existing }
        let session = DumpSession(target: target)
        let store = session.store
        store.historyLimit = historyLimit
        if let snapshot = pendingSnapshots.removeValue(forKey: target.key) {
            store.restore(from: snapshot)
        }
        store.effects.notify = { [weak self] text in
            guard let self else { return }
            self.notify(self.title(for: target), text)
        }
        store.effects.showApp = { NSApp.activate(ignoringOtherApps: true) }
        store.effects.hideApp = { NSApp.hide(nil) }
        store.effects.logReceived = { [weak self, weak session] in
            guard let self, let session else { return }
            if self.visibleTargets[target, default: 0] == 0 {
                session.unreadCount += 1
                if let last = session.store.currentScreen.entries.last,
                   last.logType == .exception || last.color == "red" {
                    session.unreadErrorCount += 1
                }
            }
            if self.notifyOnPause, session.store.currentScreen.entries.last?.logType == .lock {
                self.notify(self.title(for: target), "Execution paused — open Dumps to continue.")
            }
        }
        store.onChange = { [weak self] in self?.scheduleSave() }
        sessions[target] = session
        return session
    }

    /// Existing session, without creating one (for badges).
    func existingSession(for target: DumpTarget) -> DumpSession? {
        sessions[target]
    }

    func unreadCount(for target: DumpTarget) -> Int {
        sessions[target]?.unreadCount ?? 0
    }

    /// Tracks which streams are on screen; counts so inline + detached views can overlap briefly.
    func setVisible(_ target: DumpTarget, _ visible: Bool) {
        visibleTargets[target, default: 0] += visible ? 1 : -1
        if visibleTargets[target, default: 0] <= 0 { visibleTargets[target] = nil }
        if visible {
            sessions[target]?.unreadCount = 0
            sessions[target]?.unreadErrorCount = 0
        }
    }

    /// Streams with messages on their current screen, most recently active first.
    var activeSessions: [DumpSession] {
        sessions.values
            .filter { !$0.store.currentScreen.entries.isEmpty }
            .sorted {
                ($0.store.currentScreen.entries.last?.createdAt ?? .distantPast)
                    > ($1.store.currentScreen.entries.last?.createdAt ?? .distantPast)
            }
    }

    /// True when this stream is the one on screen in the Dumps window.
    func isDetached(_ target: DumpTarget) -> Bool {
        isWindowOpen && windowTarget == target
    }

    /// Choices for the window's project picker: every stream with dumps, plus the current one.
    var pickerTargets: [DumpTarget] {
        var targets = activeSessions.map(\.target)
        if let windowTarget, !targets.contains(windowTarget) { targets.insert(windowTarget, at: 0) }
        // Unassigned last.
        if let i = targets.firstIndex(of: .unassigned) { targets.append(targets.remove(at: i)) }
        return targets
    }

    var totalUnread: Int {
        sessions.values.reduce(0) { $0 + $1.unreadCount }
    }

    var unassignedCount: Int {
        sessions[.unassigned]?.store.currentScreen.entries.count ?? 0
    }

    func title(for target: DumpTarget) -> String {
        switch target {
        case .project(let id): return projectsProvider().first { $0.id == id }?.name ?? "Dumps"
        case .unassigned: return "Unassigned"
        }
    }

    // MARK: Project matching

    /// Matches a request to a project: source file under the project folder (longest match),
    /// then the project name/path the client sent, then Sail's container root.
    func target(for hint: DumpHint) -> DumpTarget {
        // Follow-up calls (`->green()`, `->label()`) reuse the uuid; keep them with their message.
        if let uuid = hint.uuid, let owner = sessions.values.first(where: { session in
            session.store.currentScreen.entries.contains { $0.groupUuid == uuid }
        }) {
            return owner.target
        }

        let projects = projectsProvider()
        guard !projects.isEmpty else { return .unassigned }

        func root(_ path: String) -> String {
            let standardized = (path as NSString).standardizingPath
            return standardized.hasSuffix("/") ? standardized : standardized + "/"
        }
        func longestMatch(_ path: String) -> Project? {
            let candidate = root(path)
            return projects
                .filter { candidate.hasPrefix(root($0.path)) }
                .max { $0.path.count < $1.path.count }
        }

        for file in hint.files {
            if let project = longestMatch(file) { return .project(project.id) }
        }

        if let name = hint.projectName {
            if name.hasPrefix("/") {
                if let project = longestMatch(name) { return .project(project.id) }
            } else if let project = projects.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
                    || ($0.path as NSString).lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
            }) {
                return .project(project.id)
            }
        }

        let inContainer = hint.files.contains { $0.hasPrefix(Self.containerAppRoot + "/") }
            || hint.projectName.map { root($0) == root(Self.containerAppRoot) } == true
        if inContainer, let project = containerProject(among: projects) {
            return .project(project.id)
        }
        return .unassigned
    }

    /// The Compose project a container path belongs to: the only Compose project,
    /// or the only one with containers running.
    private func containerProject(among projects: [Project]) -> Project? {
        let compose = projects.filter(\.hasDockerCompose)
        if compose.count == 1 { return compose[0] }
        let running = compose.filter { composeRunning($0.id) }
        return running.count == 1 ? running[0] : nil
    }

    // MARK: Editor

    /// Opens a dump's source file, mapping Sail container paths back to the project folder.
    func open(file: String, line: Int, target: DumpTarget) {
        let path = localPath(for: file, target: target)
        let line = max(line, 1)
        if let url = editor.url(path: path, line: line, customTemplate: customEditorURL),
           NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
            return
        }
        if let (name, args) = editor.binary, let binary = Self.findBinary(name) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = args.map { Editor.fill($0, path: path, line: line, encodePath: false) }
            try? process.run()
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func localPath(for file: String, target: DumpTarget) -> String {
        guard case .project(let id) = target,
              file.hasPrefix(Self.containerAppRoot + "/"),
              let project = projectsProvider().first(where: { $0.id == id }) else { return file }
        return project.path + file.dropFirst(Self.containerAppRoot.count)
    }

    private static func findBinary(_ name: String) -> String? {
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", NSHomeDirectory() + "/.local/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return dirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Persistence

    private func save(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: key) }

    private var sessionURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Laradeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dumps-session.json")
    }

    private func loadSnapshots() {
        guard let data = try? Data(contentsOf: sessionURL),
              let json = try? JSONValue.parse(data),
              case .object(let object)? = json["sessions"] else { return }
        for (key, value) in object.pairs where DumpTarget(key: key) != nil {
            pendingSnapshots[key] = value
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            var pairs = self.pendingSnapshots.map { ($0.key, $0.value) }
            for (target, session) in self.sessions {
                pairs.append((target.key, session.store.snapshot()))
            }
            let text = JSONValue.object(JSONObject([("sessions", .object(JSONObject(pairs)))])).serialized()
            let url = self.sessionURL
            await Task.detached { try? Data(text.utf8).write(to: url, options: .atomic) }.value
        }
    }
}
