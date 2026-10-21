import AppKit
import Foundation
import Observation
import PhpSwitcherCore

/// Homebrew PHP management (ported from phpmonit / PHP Monitor): switch the linked version,
/// extensions, php.ini limits, Xdebug, Homebrew versions and extensions, Valet, Composer.
@MainActor
@Observable
final class PhpManager {
    /// Everything shown in the PHP page, loaded together.
    private(set) var snapshot = Snapshot()
    private(set) var loaded = false
    /// Step in progress (e.g. "Running: brew link php@8.3 --overwrite --force"); nil when idle.
    private(set) var busy: String?
    /// Last finished action ("✓ Switched to PHP 8.3"), shown under the page header.
    var lastMessage: String?
    var error: String?
    /// Output of the last Composer global update.
    private(set) var composerOutput: String?
    /// Set after a successful switch: running `php artisan …` processes still use the old
    /// binary until restarted. The UI offers a Restart and clears it.
    var pendingProcessRestart = false
    /// `brew outdated` is slow, so it runs only when the versions section asks for it.
    private(set) var checkedOutdated = false

    let env: PhpEnvironment?
    /// Called after the linked PHP changes (refreshes the toolbar's PHP monitor).
    var onActiveVersionChanged: (() -> Void)?

    private var watcher: BinDirectoryWatcher?

    init() {
        if let prefix = Homebrew.detectPrefix() {
            env = PhpEnvironment(homebrew: Homebrew(prefix: prefix, shell: SystemShell(homebrewPrefix: prefix)))
        } else {
            env = nil
        }
        refresh()
        // Like PHP Monitor: a `brew link` in Terminal updates Laradeck too.
        if let prefix = env?.homebrew.prefix {
            watcher = BinDirectoryWatcher(path: "\(prefix)/bin") { [weak self] in
                Task { @MainActor in
                    guard let self, self.busy == nil else { return }
                    self.refresh()
                    self.onActiveVersionChanged?()
                }
            }
        }
    }

    var isHomebrewInstalled: Bool { env != nil }
    var usesValet: Bool { env?.usesValet ?? false }
    var isComposerInstalled: Bool { env?.composer.isInstalled ?? false }
    var active: ActivePhp? { snapshot.active }
    var installed: [PhpInstallation] { snapshot.installed }

    func isActive(_ installation: PhpInstallation) -> Bool { snapshot.active?.formula == installation.formula }

    // MARK: Loading

    func refresh(includeOutdated: Bool = false) {
        guard let env else {
            loaded = true
            return
        }
        let wantsOutdated = includeOutdated || checkedOutdated
        Task {
            let snap = await Task.detached { await env.snapshot(includeOutdated: wantsOutdated) }.value
            snapshot = snap
            loaded = true
            if wantsOutdated { checkedOutdated = true }
        }
    }

    // MARK: Switching

    /// Unlinks every PHP, links the target, fixes Valet if present, then checks `php -v`.
    func switchTo(_ target: PhpInstallation) async -> Bool {
        guard let env, busy == nil else { return false }
        let installed = snapshot.installed
        busy = "Switching to PHP \(target.version.short)…"
        error = nil
        defer {
            busy = nil
            refresh()
            onActiveVersionChanged?()
        }
        do {
            let outcome = try await env.switcher.switchTo(target, installed: installed) { step in
                Task { @MainActor [weak self] in self?.busy = "Running: \(step)" }
            }
            lastMessage = "✓ Switched to PHP \(outcome.active.version)"
                + (outcome.notes.isEmpty ? "" : " — " + outcome.notes.joined(separator: "; "))
            pendingProcessRestart = true
            return true
        } catch {
            self.error = Self.explain(error)
            lastMessage = nil
            return false
        }
    }

    // MARK: Configuration

    func config() -> PhpConfig? {
        guard let env, let active = snapshot.active else { return nil }
        return env.config(for: active)
    }

    func toggle(_ ext: PhpExtension) {
        perform("\(ext.enabled ? "Disable" : "Enable") \(ext.name)") { env, active in
            try env.config(for: active).toggle(ext)
            await env.restartActivePhpIfRunning(active)
            return "\(ext.name) \(ext.enabled ? "disabled" : "enabled")"
        }
    }

    func setLimit(_ key: String, _ value: String) {
        let value = value.trimmingCharacters(in: .whitespaces).uppercased()
        guard PhpConfig.isValidSize(value) else {
            error = "“\(value)” is not a valid value. Use for example 256M, 1G or -1."
            return
        }
        perform("Set \(key) = \(value)") { env, active in
            try await env.config(for: active).set(key, to: value)
            await env.restartActivePhpIfRunning(active)
            return "\(key) = \(value)"
        }
    }

    func setXdebugMode(_ mode: String) {
        perform("Xdebug mode \(mode)") { env, active in
            try await env.config(for: active).setXdebugMode(mode)
            await env.restartActivePhpIfRunning(active)
            return "xdebug.mode = \(mode)"
        }
    }

    func openPhpInfo() {
        perform("phpinfo()") { env, active in
            let page = try await env.config(for: active).phpInfoPage(phpCgi: env.phpCgi(for: active.formula))
            await MainActor.run { _ = NSWorkspace.shared.open(page) }
            return "phpinfo() opened"
        }
    }

    // MARK: Homebrew versions and extensions

    func checkForUpdates() { refresh(includeOutdated: true) }

    func installVersion(_ formula: String) {
        performBrew("Install \(formula)") { env in try await env.versionManager.install(formula) }
    }

    func upgradeVersion(_ formula: String) {
        performBrew("Upgrade \(formula)") { env in try await env.versionManager.upgrade(formula) }
    }

    func uninstallVersion(_ formula: String) {
        performBrew("Uninstall \(formula)") { env in try await env.versionManager.uninstall(formula) }
    }

    func installExtensionTap() {
        performBrew("brew tap shivammathur/extensions") { env in try await env.extensionManager.installTap() }
    }

    func installExtension(_ ext: BrewExtension) {
        perform("Install \(ext.formula)") { env, active in
            try await env.extensionManager.install(ext)
            await env.restartActivePhpIfRunning(active)
            return "\(ext.formula) installed"
        }
    }

    func removeExtension(_ ext: BrewExtension) {
        perform("Remove \(ext.formula)") { env, active in
            try await env.extensionManager.remove(ext)
            await env.restartActivePhpIfRunning(active)
            return "\(ext.formula) removed"
        }
    }

    // MARK: Services

    var keyServices: [ServiceInfo] { snapshot.keyServices(usesValet: usesValet) }

    func service(_ action: ServiceAction, _ name: String) {
        performBrew("\(action.rawValue.capitalized) \(name)") { env in
            let result = try await env.services.perform(action, name)
            if !result.succeeded {
                throw BrewError.failed(command: "brew services \(action.rawValue) \(name)",
                                       output: result.stderr + result.stdout)
            }
        }
    }

    // MARK: Valet

    func valetSite(at path: String) -> ValetSite? {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return snapshot.sites.first { $0.path == target }
    }

    func setSecure(_ site: ValetSite, _ secure: Bool) {
        performBrew("\(secure ? "Secure" : "Unsecure") \(site.domain)") { env in
            guard let valet = env.valet else { return }
            if secure { try await valet.secure(site) } else { try await valet.unsecure(site) }
        }
    }

    func isolate(_ site: ValetSite, to installation: PhpInstallation?) async -> Bool {
        let title = installation.map { "Isolate \(site.domain) to PHP \($0.version.short)" }
            ?? "Use global PHP for \(site.domain)"
        return await run(title) { env in
            guard let valet = env.valet else { return }
            if let installation {
                try await valet.isolate(site, formula: installation.formula)
            } else {
                try await valet.unisolate(site)
            }
        }
    }

    // MARK: Composer

    func composerGlobalUpdate() {
        guard let env, busy == nil else { return }
        busy = "composer global update…"
        error = nil
        Task {
            do {
                let output = try await env.composer.globalUpdate()
                composerOutput = output
                lastMessage = "✓ " + (output.split(separator: "\n").last.map(String.init) ?? "Composer updated")
            } catch {
                self.error = Self.explain(error)
            }
            busy = nil
        }
    }

    // MARK: Helpers

    /// Runs an action on the active PHP, with a busy message, then reloads.
    private func perform(_ title: String,
                         _ work: @escaping @Sendable (PhpEnvironment, ActivePhp) async throws -> String?) {
        guard let env, let active = snapshot.active, busy == nil else { return }
        busy = title + "…"
        error = nil
        Task {
            do {
                let result = try await work(env, active)
                lastMessage = "✓ " + (result ?? title)
            } catch {
                self.error = Self.explain(error)
            }
            busy = nil
            refresh()
        }
    }

    private func performBrew(_ title: String, _ work: @escaping @Sendable (PhpEnvironment) async throws -> Void) {
        Task { _ = await run(title, work) }
    }

    @discardableResult
    private func run(_ title: String, _ work: @escaping @Sendable (PhpEnvironment) async throws -> Void) async -> Bool {
        guard let env, busy == nil else { return false }
        busy = title + "…"
        error = nil
        defer {
            busy = nil
            refresh()
        }
        do {
            try await work(env)
            lastMessage = "✓ " + title
            return true
        } catch {
            self.error = Self.explain(error)
            return false
        }
    }

    /// Adds the fix for the most common failure: Valet's sudo rules aren't installed.
    static func explain(_ error: Error) -> String {
        let message = error.localizedDescription
        if message.contains("a password is required") || message.contains("sudo:") {
            return message + "\n\nValet needs passwordless sudo for this. Run `valet trust` in Terminal once, then try again."
        }
        return message
    }
}

/// Calls `onChange` (debounced) when files are added to or removed from a directory,
/// e.g. when `brew link` rewrites the `php` symlink in `<prefix>/bin`.
private final class BinDirectoryWatcher: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject
    private var pending: DispatchWorkItem?

    init?(path: String, debounce: TimeInterval = 1.0, onChange: @escaping @Sendable () -> Void) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let queue = DispatchQueue(label: "laradeck.php.bin-watcher")
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
        source.setEventHandler { [weak self] in
            // brew link/unlink touches many symlinks at once; wait until it settles.
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
