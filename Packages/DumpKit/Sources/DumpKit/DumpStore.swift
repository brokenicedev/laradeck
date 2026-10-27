import Foundation
import Observation

/// Holds every screen and applies incoming dump requests to them.
@Observable
@MainActor
public final class DumpStore {
    public struct Effects {
        public var notify: (String) -> Void = { _ in }
        public var showApp: () -> Void = {}
        public var hideApp: () -> Void = {}
        /// Called after a row was added (used to surface the viewer when a log is received).
        public var logReceived: () -> Void = {}
        public init() {}
    }

    public private(set) var screens: [DumpScreen]
    public var currentScreenID: UUID
    public private(set) var archived: [DumpScreen] = []
    public private(set) var locks: [String: LockStatus] = [:]
    public private(set) var screenColor: String?
    /// Bumped on every `confetti` action so the UI can animate.
    public private(set) var confettiCounter = 0
    /// Bumped on every new row so the UI can scroll.
    public private(set) var lastAppendedID: UUID?
    public private(set) var knownProjects: [String] = []
    public private(set) var knownHosts: [String] = []

    public var isPaused = false
    public var historyLimit = 1000
    public var maxArchived = 20

    /// ds() `time_track` start times by label.
    @ObservationIgnored var dsTimers: [String: Double] = [:]

    @ObservationIgnored public var effects = Effects()
    @ObservationIgnored public var onChange: () -> Void = {}

    public init() {
        let first = DumpScreen(name: DumpStore.defaultScreenName())
        screens = [first]
        currentScreenID = first.id
    }

    static func defaultScreenName(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return "Screen \(f.string(from: date))"
    }

    public var currentScreen: DumpScreen {
        screens.first { $0.id == currentScreenID } ?? screens[screens.count - 1]
    }

    private var currentIndex: Int {
        screens.firstIndex { $0.id == currentScreenID } ?? screens.count - 1
    }

    // MARK: Ingest

    /// Applies one POSTed dump request: `{uuid, payloads: [{type, content, origin}], meta}`.
    public func ingest(_ request: JSONValue) {
        let uuid = request["uuid"]?.string ?? UUID().uuidString
        let meta = request["meta"]
        let projectName = meta?["project_name"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        for payload in request["payloads"]?.array ?? [] {
            apply(payload: payload, uuid: uuid, projectName: projectName)
        }
        onChange()
    }

    private func apply(payload: JSONValue, uuid: String, projectName: String?) {
        guard !isPaused else { return }
        let type = payload["type"]?.string ?? "log"
        let content = payload["content"] ?? .null
        let origin = Origin(json: payload["origin"])
        remember(project: projectName, host: origin.hostname)

        if let action = ActionType(rawValue: type) {
            switch action {
            case .remove:
                screens[currentIndex].entries.removeAll { $0.groupUuid == uuid }
            case .hide:
                modify(uuid) { $0.collapsed = true }
            case .clearAll:
                clearCurrentScreen()
            case .newScreen:
                let name = content["name"]?.string ?? ""
                newScreen(named: name)
            case .color:
                modify(uuid) { $0.color = content["color"]?.string }
            case .label:
                modify(uuid) { $0.label = content["label"]?.string }
            case .size:
                modify(uuid) { $0.size = content["size"]?.string }
            case .notify:
                effects.notify(content["value"]?.displayString ?? "")
            case .createLock:
                let name = content["name"]?.string ?? uuid
                locks[name] = .active
                append(DumpEntry(groupUuid: uuid, type: LogType.lock.rawValue, content: content, origin: origin, projectName: projectName))
            case .showApp:
                effects.showApp()
            case .hideApp:
                effects.hideApp()
            case .screenColor:
                screenColor = content["color"]?.string
            case .confetti:
                confettiCounter += 1
            case .expand:
                modify(uuid) { $0.expand = content; $0.collapsed = false }
            }
            return
        }

        append(DumpEntry(groupUuid: uuid, type: type, content: content, origin: origin, projectName: projectName))
    }

    func append(_ entry: DumpEntry) {
        let i = currentIndex
        screens[i].entries.append(entry)
        if historyLimit > 0, screens[i].entries.count > historyLimit {
            screens[i].entries.removeFirst(screens[i].entries.count - historyLimit)
        }
        lastAppendedID = entry.id
        effects.logReceived()
    }

    /// Stateful actions are ignored when no row has the uuid ("No logs found to apply action to").
    func modify(_ uuid: String, _ change: (inout DumpEntry) -> Void) {
        let i = currentIndex
        for j in screens[i].entries.indices where screens[i].entries[j].groupUuid == uuid {
            change(&screens[i].entries[j])
        }
    }

    private func remember(project: String?, host: String?) {
        if let project, !knownProjects.contains(project) { knownProjects.append(project) }
        if let host, !knownHosts.contains(host) { knownHosts.append(host) }
    }

    /// Moves every row of a group to the screen with that name (created if needed).
    /// The current screen stays selected, like ds() tabs; "home" means the current screen.
    func moveGroup(_ uuid: String, toScreenNamed name: String) {
        let from = currentIndex
        let moved = screens[from].entries.filter { $0.groupUuid == uuid }
        let target: Int
        if name.isEmpty || name.lowercased() == "home" {
            return
        } else if let i = screens.firstIndex(where: { $0.name == name }) {
            target = i
        } else {
            screens.append(DumpScreen(name: name))
            target = screens.count - 1
        }
        guard target != from else { return }
        screens[from].entries.removeAll { $0.groupUuid == uuid }
        screens[target].entries.append(contentsOf: moved)
    }

    // MARK: Locks

    /// Answer for `GET /locks/:name`, polled by the client while paused until it is no longer active.
    public func lockResponse(_ name: String) -> JSONValue {
        switch locks[name] {
        case .active: return ["active": true, "stop_execution": false]
        case .stopped: return ["active": false, "stop_execution": true]
        case .continued, .none: return ["active": false, "stop_execution": false]
        }
    }

    public func resolveLock(_ name: String, stop: Bool) {
        guard locks[name] == .active else { return }
        locks[name] = stop ? .stopped : .continued
        onChange()
    }

    public func resolveAllLocks() {
        for (name, status) in locks where status == .active { locks[name] = .continued }
        onChange()
    }

    // MARK: User actions

    public func newScreen(named name: String = "") {
        let screen = DumpScreen(name: name.isEmpty ? DumpStore.defaultScreenName() : name)
        screens.append(screen)
        currentScreenID = screen.id
        screenColor = nil
        onChange()
    }

    /// Clears the current screen, keeping a copy in the archive (archive before clearing).
    public func clearCurrentScreen() {
        let i = currentIndex
        if !screens[i].entries.isEmpty {
            archived.insert(screens[i], at: 0)
            if archived.count > maxArchived { archived.removeLast(archived.count - maxArchived) }
        }
        screens[i].entries.removeAll()
        screenColor = nil
        // Pending pauses would otherwise block the client forever.
        resolveAllLocks()
        onChange()
    }

    public func clearAllScreens() {
        for screen in screens where !screen.entries.isEmpty { archived.insert(screen, at: 0) }
        if archived.count > maxArchived { archived.removeLast(archived.count - maxArchived) }
        let fresh = DumpScreen(name: DumpStore.defaultScreenName())
        screens = [fresh]
        currentScreenID = fresh.id
        screenColor = nil
        resolveAllLocks()
        onChange()
    }

    public func deleteScreen(_ id: UUID) {
        screens.removeAll { $0.id == id }
        if screens.isEmpty { screens = [DumpScreen(name: DumpStore.defaultScreenName())] }
        if !screens.contains(where: { $0.id == currentScreenID }) { currentScreenID = screens[screens.count - 1].id }
        onChange()
    }

    public func removeEntry(_ id: UUID) {
        screens[currentIndex].entries.removeAll { $0.id == id }
        onChange()
    }

    public func toggleCollapsed(_ id: UUID) {
        let i = currentIndex
        guard let j = screens[i].entries.firstIndex(where: { $0.id == id }) else { return }
        screens[i].entries[j].collapsed.toggle()
        onChange()
    }

    public func clearArchive() {
        archived.removeAll()
        onChange()
    }

    // MARK: Persistence

    public func snapshot() -> JSONValue {
        [
            "version": 1,
            "current_screen": .string(currentScreenID.uuidString),
            "screens": .array(screens.map(\.json)),
            "archived": .array(archived.map(\.json)),
        ]
    }

    public func restore(from json: JSONValue) {
        let restored = (json["screens"]?.array ?? []).compactMap(DumpScreen.init(json:))
        guard !restored.isEmpty else { return }
        screens = restored
        archived = (json["archived"]?.array ?? []).compactMap(DumpScreen.init(json:))
        let current = json["current_screen"]?.string.flatMap(UUID.init(uuidString:))
        currentScreenID = restored.contains { $0.id == current } ? current! : restored[restored.count - 1].id
        // Restored pause rows belong to processes that are gone.
        for entry in restored.flatMap(\.entries) { if let n = entry.lockName { locks[n] = .continued } }
        for entry in restored.flatMap(\.entries) {
            remember(project: entry.projectName, host: entry.origin.hostname)
        }
    }
}
