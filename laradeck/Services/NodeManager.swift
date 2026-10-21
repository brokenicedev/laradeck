import Foundation
import Observation

/// One Node.js version installed by nvm (`$NVM_DIR/versions/node/v20.19.2`).
nonisolated struct NodeInstallation: Hashable, Identifiable, Sendable {
    let version: NodeVersion
    let binPath: String
    var id: NodeVersion { version }
}

/// Reads nvm's folders directly — no shell needed, so it's cheap enough to call while spawning
/// every process.
nonisolated enum NvmLocator {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var shellDirectory: String?

    /// Tools that live in each nvm version's `bin` and must come from the project's Node.
    static let nodeTools: Set<String> = ["node", "npm", "npx", "corepack", "pnpm", "pnpx", "yarn", "yarnpkg"]

    /// `$NVM_DIR` as the login shell sets it (found once at launch by `NodeManager`).
    static func setShellDirectory(_ path: String?) {
        lock.lock()
        shellDirectory = path
        lock.unlock()
    }

    /// The nvm install folder, or nil when nvm isn't installed.
    static func directory() -> String? {
        lock.lock()
        let fromShell = shellDirectory
        lock.unlock()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            fromShell,
            ProcessInfo.processInfo.environment["NVM_DIR"],
            "\(home)/.nvm",
            "\(home)/.config/nvm",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: "\($0)/nvm.sh") }
    }

    static func installed(in nvmDir: String) -> [NodeInstallation] {
        let root = "\(nvmDir)/versions/node"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return names.compactMap { name -> NodeInstallation? in
            guard name.hasPrefix("v"), let version = NodeVersion(name) else { return nil }
            let bin = "\(root)/\(name)/bin"
            guard FileManager.default.isExecutableFile(atPath: "\(bin)/node") else { return nil }
            return NodeInstallation(version: version, binPath: bin)
        }
        .sorted { $0.version > $1.version }
    }

    /// Resolves `alias/default` (which may point at another alias, "22", "lts/*", "node"…).
    static func defaultInstallation(in nvmDir: String, installed: [NodeInstallation]) -> NodeInstallation? {
        var name = "default"
        for _ in 0..<5 {
            let aliasFile = "\(nvmDir)/alias/\(name)"
            guard let text = try? String(contentsOfFile: aliasFile, encoding: .utf8) else { break }
            name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "system" { return nil }
        }
        guard name != "default", let requirement = NodeRequirement(name) else { return nil }
        let best = requirement.bestMatch(in: installed.map(\.version))
        return installed.first { $0.version == best }
    }

    /// The `bin` folder of the Node version pinned to a project, if it's still installed.
    static func binDirectory(for project: Project) -> String? {
        guard project.environment == .native,
              let pinned = project.nodeVersion,
              let version = NodeVersion(pinned),
              let nvmDir = directory() else { return nil }
        let bin = "\(nvmDir)/versions/node/v\(version)/bin"
        return FileManager.default.isExecutableFile(atPath: "\(bin)/node") ? bin : nil
    }

    /// Puts the project's Node first in PATH, the same as `nvm use` would.
    static func apply(to environment: inout [String: String], for project: Project) {
        guard let bin = binDirectory(for: project) else { return }
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        // Drop other nvm versions so nested `node` lookups can't find them first.
        let others = path.split(separator: ":").map(String.init).filter { !$0.contains("/versions/node/") }
        environment["PATH"] = ([bin] + others).joined(separator: ":")
        environment["NVM_BIN"] = bin
    }
}

/// What the dashboard shows when the project's Node doesn't fit its `.nvmrc` / `engines.node`.
struct ProjectNodeMismatch: Equatable {
    let requirement: ProjectNodeRequirement
    /// The Node the project would run with right now (pinned or nvm default); nil if none.
    let current: NodeInstallation?
    let isPinned: Bool
    /// Newest installed version that fits, if any.
    let suggestion: NodeInstallation?
}

/// nvm integration: lists installed Node versions, the nvm default, and lets each project
/// run with its own version (Laradeck puts that version first in the PATH of the processes it starts).
@MainActor
@Observable
final class NodeManager {
    private(set) var nvmDirectory: String?
    private(set) var installed: [NodeInstallation] = []
    private(set) var defaultInstallation: NodeInstallation?
    /// Step in progress (e.g. "nvm install 22…"); nil when idle.
    private(set) var busy: String?
    var error: String?
    /// Projects whose Node changed while their npm/vite processes were running.
    var pendingRestart: Set<UUID> = []

    private var watchers: [DirectoryWatcher] = []

    init() {
        refresh()
        // A GUI app doesn't see a custom $NVM_DIR exported in .zshrc; ask the login shell once.
        Task {
            let env = await RuntimeResolver.shared.loginShellEnvironment()
            if let dir = env["NVM_DIR"], dir != nvmDirectory {
                NvmLocator.setShellDirectory(dir)
                refresh()
            }
        }
    }

    var isNvmInstalled: Bool { nvmDirectory != nil }

    func refresh() {
        let dir = NvmLocator.directory()
        // Re-created each time: `alias/default` may have been replaced rather than rewritten.
        startWatching(dir)
        nvmDirectory = dir
        guard let dir else {
            installed = []
            defaultInstallation = nil
            return
        }
        installed = NvmLocator.installed(in: dir)
        defaultInstallation = NvmLocator.defaultInstallation(in: dir, installed: installed)
    }

    /// `nvm install` / `nvm alias default` in Terminal update Laradeck too.
    private func startWatching(_ dir: String?) {
        watchers = []
        guard let dir else { return }
        for path in ["\(dir)/versions/node", "\(dir)/alias", "\(dir)/alias/default"] {
            if let watcher = DirectoryWatcher(path: path, onChange: { [weak self] in
                Task { @MainActor in self?.refresh() }
            }) {
                watchers.append(watcher)
            }
        }
    }

    // MARK: Projects

    func pinned(for project: Project) -> NodeInstallation? {
        guard project.environment == .native,
              let text = project.nodeVersion, let version = NodeVersion(text) else { return nil }
        return installed.first { $0.version == version }
    }

    /// The Node the project's processes run with.
    func current(for project: Project) -> NodeInstallation? {
        pinned(for: project) ?? defaultInstallation
    }

    /// nil when the project fits its Node (or there's nothing to check).
    func mismatch(for project: Project) -> ProjectNodeMismatch? {
        guard isNvmInstalled, let requirement = ProjectNodeRequirement.read(for: project) else { return nil }
        let current = current(for: project)
        if let current, requirement.requirement.satisfies(current.version) { return nil }
        let best = requirement.requirement.bestMatch(in: installed.map(\.version))
        return ProjectNodeMismatch(
            requirement: requirement,
            current: current,
            isPinned: pinned(for: project) != nil,
            suggestion: installed.first { $0.version == best }
        )
    }

    // MARK: nvm commands

    /// Last finished action ("✓ nvm install 22"), shown on the Node page.
    var lastMessage: String?

    func isDefault(_ installation: NodeInstallation) -> Bool { defaultInstallation == installation }

    /// Runs `nvm install <version>` (nvm is a shell function, so it needs `nvm.sh` sourced first).
    func install(_ version: String) async -> Bool {
        await runNvm(["install", version], title: "nvm install \(version)")
    }

    func uninstall(_ installation: NodeInstallation) async -> Bool {
        await runNvm(["uninstall", installation.version.description],
                     title: "nvm uninstall \(installation.version.description)")
    }

    /// `nvm alias default <version>`: the Node new terminals (and unpinned projects) use.
    func setDefault(_ installation: NodeInstallation) async -> Bool {
        await runNvm(["alias", "default", installation.version.description],
                     title: "nvm alias default \(installation.version.description)")
    }

    @discardableResult
    private func runNvm(_ arguments: [String], title: String) async -> Bool {
        guard let dir = nvmDirectory, busy == nil else { return false }
        busy = title + "…"
        error = nil
        defer {
            busy = nil
            refresh()
        }
        let result = await Task.detached { Self.runNvm(dir: dir, arguments: arguments) }.value
        if result.status != 0 {
            error = "\(title) failed:\n" + result.output.suffix(800)
            lastMessage = nil
            return false
        }
        lastMessage = "✓ " + title
        return true
    }

    nonisolated private static func runNvm(dir: String, arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let quoted = arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        // --no-use: don't activate the default first (nvm won't uninstall the active version).
        process.arguments = ["-c", "export NVM_DIR=\"$1\"; . \"$NVM_DIR/nvm.sh\" --no-use && nvm \(quoted)", "zsh", dir]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: Available versions

    /// Newest release of each major from nodejs.org (fetched when the Node page asks).
    private(set) var releases: [NodeRelease] = []
    private(set) var releasesError: String?
    private(set) var loadingReleases = false

    func loadReleases(force: Bool = false) {
        guard force || (releases.isEmpty && !loadingReleases) else { return }
        loadingReleases = true
        releasesError = nil
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: URL(string: "https://nodejs.org/dist/index.json")!)
                releases = NodeRelease.latestPerMajor(fromIndexJSON: data)
            } catch {
                releasesError = "Could not load the Node release list: \(error.localizedDescription)"
            }
            loadingReleases = false
        }
    }

    /// A newer release of the same major, when the newest installed one is behind.
    func update(for installation: NodeInstallation) -> NodeRelease? {
        let newestOfMajor = installed.filter { $0.version.major == installation.version.major }.map(\.version).max()
        guard newestOfMajor == installation.version,
              let release = releases.first(where: { $0.version.major == installation.version.major }),
              release.version > installation.version else { return nil }
        return release
    }
}

/// A Node release from nodejs.org's `dist/index.json`.
nonisolated struct NodeRelease: Hashable, Identifiable, Sendable {
    let version: NodeVersion
    /// LTS codename ("Jod"), nil for Current / odd releases.
    let lts: String?
    let date: String
    var id: NodeVersion { version }

    /// End of life majors are dropped: the list keeps majors ≥ 18 only.
    static func latestPerMajor(fromIndexJSON data: Data, minimumMajor: Int = 18) -> [NodeRelease] {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var best: [Int: NodeRelease] = [:]
        for entry in entries {
            guard let text = entry["version"] as? String, let version = NodeVersion(text),
                  version.major >= minimumMajor else { continue }
            let release = NodeRelease(version: version, lts: entry["lts"] as? String,
                                      date: entry["date"] as? String ?? "")
            if let current = best[version.major], current.version >= version { continue }
            best[version.major] = release
        }
        return best.values.sorted { $0.version > $1.version }
    }
}

/// Calls `onChange` (debounced) when entries are added to or removed from a directory.
private final class DirectoryWatcher: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject
    private var pending: DispatchWorkItem?

    init?(path: String, debounce: TimeInterval = 1.0, onChange: @escaping @Sendable () -> Void) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let queue = DispatchQueue(label: "laradeck.nvm.watcher")
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in
            self?.pending?.cancel()
            let work = DispatchWorkItem(block: onChange)
            self?.pending = work
            queue.asyncAfter(deadline: .now() + debounce, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}
