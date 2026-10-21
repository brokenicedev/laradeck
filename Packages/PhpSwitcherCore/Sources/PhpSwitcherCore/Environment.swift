import Foundation

/// Everything the menu shows, loaded in one go.
public struct Snapshot: Sendable {
    public var installed: [PhpInstallation] = []
    public var active: ActivePhp?
    public var services: [ServiceInfo] = []
    public var extensions: [PhpExtension] = []
    public var limits: PhpLimits?
    public var xdebugMode: String?
    public var brewExtensions: [BrewExtension] = []
    public var extensionTapInstalled = false
    public var phpFormulae: [PhpFormulaStatus] = []
    public var sites: [ValetSite] = []
    public var valetVersion: String?
    public var iniFiles: [String] = []
    public var errorLog: String?

    public init() {}

    /// The services PHP Monitor shows a status for: the active PHP, nginx, dnsmasq.
    public func keyServices(usesValet: Bool) -> [ServiceInfo] {
        var names: [String] = []
        if let active { names.append(active.formula) }
        if usesValet { names += ["nginx", "dnsmasq"] }
        return names.map { name in
            services.first { $0.name == name } ?? ServiceInfo(name: name, status: "none")
        }
    }
}

/// Wires all the parts together for the app and the CLI.
public struct PhpEnvironment: Sendable {
    public let homebrew: Homebrew
    public let valet: Valet?
    public let services: Services
    public let switcher: PhpSwitcher
    public let extensionManager: ExtensionManager
    public let versionManager: PhpVersionManager
    public let composer: Composer

    public init(homebrew: Homebrew) {
        self.homebrew = homebrew
        let valet = Valet(homebrew: homebrew)
        self.valet = valet.isInstalled ? valet : nil
        self.services = Services(homebrew: homebrew, useSudo: valet.isInstalled)
        self.switcher = PhpSwitcher(homebrew: homebrew, services: services, valet: self.valet)
        self.extensionManager = ExtensionManager(homebrew: homebrew)
        self.versionManager = PhpVersionManager(homebrew: homebrew)
        self.composer = Composer(homebrew: homebrew)
    }

    public var usesValet: Bool { valet != nil }

    /// Config for the linked PHP version.
    public func config(for active: ActivePhp) -> PhpConfig {
        PhpConfig(
            homebrew: homebrew,
            phpBinary: homebrew.linkedPhpBinary,
            etcDirectory: homebrew.etcDirectory(for: active.version)
        )
    }

    public func phpCgi(for formula: String) -> String {
        "\(homebrew.prefix)/opt/\(formula)/bin/php-cgi"
    }

    /// Restarts the active PHP-FPM service after a config change, if it is running
    /// (PHP Monitor's `auto_restart_after_extension_toggle`).
    public func restartActivePhpIfRunning(_ active: ActivePhp?) async {
        guard let active, await services.runningPhpServices().contains(active.formula) else { return }
        _ = try? await services.perform(.restart, active.formula)
    }

    public func snapshot(includeOutdated: Bool = true) async -> Snapshot {
        var snap = Snapshot()
        snap.installed = await homebrew.installedVersions()
        snap.active = await homebrew.activePhp()
        snap.services = await services.list()

        if let active = snap.active {
            let config = config(for: active)
            snap.iniFiles = await config.iniFiles()
            snap.extensions = await config.extensions()
            snap.limits = await config.limits()
            if snap.extensions.contains(where: { $0.name == "xdebug" && $0.enabled }) {
                snap.xdebugMode = await config.xdebugMode() ?? "develop"
            }
            snap.errorLog = await config.errorLogPath()
            snap.brewExtensions = extensionManager.available(for: active.version)
        }
        snap.extensionTapInstalled = extensionManager.isTapInstalled

        let outdated = includeOutdated ? await versionManager.outdated() : []
        snap.phpFormulae = versionManager.formulae(installed: snap.installed, outdated: outdated)

        if let valet {
            snap.sites = valet.sites()
            snap.valetVersion = await valet.version()
        }
        return snap
    }
}
