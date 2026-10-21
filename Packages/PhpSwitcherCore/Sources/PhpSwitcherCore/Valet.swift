import Foundation

public struct ValetSite: Sendable, Hashable, Identifiable {
    public let name: String
    public let path: String
    public let tld: String
    public let secured: Bool
    /// "8.2" when the site is pinned to a PHP version with `valet isolate`.
    public let isolatedVersion: String?
    /// true for `valet link`, false for sites found in a parked folder.
    public let linked: Bool

    public var id: String { name }
    public var domain: String { "\(name).\(tld)" }
    public var url: URL { URL(string: "\(secured ? "https" : "http")://\(domain)")! }
}

public enum ValetError: Error, LocalizedError {
    case stubMissing(String)

    public var errorDescription: String? {
        switch self {
        case .stubMissing(let path): return "Valet's FPM template was not found at \(path)."
        }
    }
}

/// Laravel Valet support, based on what PHP Monitor reads and runs:
/// `~/.config/valet/config.json` (tld + parked `paths`), `Certificates/` for
/// HTTPS, `Nginx/<domain>` with `ISOLATED_PHP_VERSION=` for isolated sites,
/// per-version FPM sockets (`valet84.sock`) and the `valet.sock` symlink.
public struct Valet: Sendable {
    public let home: String
    public let homebrew: Homebrew

    public init(home: String = NSHomeDirectory(), homebrew: Homebrew) {
        self.home = home
        self.homebrew = homebrew
    }

    public var configDirectory: String { "\(home)/.config/valet" }
    public var valetPackage: String { "\(home)/.composer/vendor/laravel/valet" }

    /// Valet is in use when its config exists and the `valet` command is available.
    public var isInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: "\(configDirectory)/config.json")
            && (fm.isExecutableFile(atPath: "\(homebrew.prefix)/bin/valet")
                || fm.isExecutableFile(atPath: "\(home)/.composer/vendor/bin/valet"))
    }

    // MARK: Config

    public struct Config: Sendable, Decodable, Equatable {
        public let tld: String
        public let paths: [String]
    }

    public func config() -> Config? {
        guard let data = FileManager.default.contents(atPath: "\(configDirectory)/config.json") else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    /// Goes through `run` because the `valet` script re-launches itself with sudo,
    /// and only the `<prefix>/bin/valet` path is covered by the passwordless rule.
    public func version() async -> String? {
        guard let result = try? await run("--version") else { return nil }
        return VersionNumber.parse(result.stdout)?.description
    }

    /// Folder names that can be a hostname. Valet can't serve e.g. "site (backup)".
    static func isValidSiteName(_ name: String) -> Bool {
        name.range(of: #"^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$"#, options: .regularExpression) != nil
    }

    // MARK: Sites

    public func sites() -> [ValetSite] {
        guard let config = config() else { return [] }
        let fm = FileManager.default
        let sitesDir = "\(configDirectory)/Sites"
        var result: [String: ValetSite] = [:]

        // Valet checks the Sites folder (links) before parked folders.
        let folders = [sitesDir] + config.paths.filter { $0 != sitesDir }
        for folder in folders {
            for entry in ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).sorted() where !entry.hasPrefix(".") {
                let name = entry.lowercased()
                guard result[name] == nil, Self.isValidSiteName(name) else { continue }
                let path = URL(fileURLWithPath: "\(folder)/\(entry)").resolvingSymlinksInPath().path
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                let domain = "\(name).\(config.tld)"
                result[name] = ValetSite(
                    name: name,
                    path: path,
                    tld: config.tld,
                    secured: fm.fileExists(atPath: "\(configDirectory)/Certificates/\(domain).crt"),
                    isolatedVersion: isolatedVersion(domain: domain),
                    linked: folder == sitesDir
                )
            }
        }
        return result.values.sorted { $0.name < $1.name }
    }

    func isolatedVersion(domain: String) -> String? {
        guard let contents = try? String(contentsOfFile: "\(configDirectory)/Nginx/\(domain)", encoding: .utf8) else {
            return nil
        }
        return Self.parseIsolatedVersion(contents)
    }

    /// Uses PHP Monitor's regex `(ISOLATED_PHP_VERSION=(php)?(@)?)((?<major>\d)(.)?(?<minor>\d))`.
    public static func parseIsolatedVersion(_ nginxConfig: String) -> String? {
        let regex = try! NSRegularExpression(
            pattern: #"(ISOLATED_PHP_VERSION=(php)?(@)?)((?<major>\d)(.)?(?<minor>\d))"#
        )
        let range = NSRange(nginxConfig.startIndex..., in: nginxConfig)
        guard let match = regex.firstMatch(in: nginxConfig, range: range),
              let major = Range(match.range(withName: "major"), in: nginxConfig),
              let minor = Range(match.range(withName: "minor"), in: nginxConfig) else { return nil }
        return "\(nginxConfig[major]).\(nginxConfig[minor])"
    }

    /// PHP versions (X.Y) used by isolated sites. Their FPM services must keep running.
    public func isolatedVersions() -> Set<String> {
        Set(sites().compactMap(\.isolatedVersion))
    }

    // MARK: FPM

    /// Valet 4 names each version's socket `valet` + digits, e.g. `valet84.sock`.
    public static func socketName(for version: VersionNumber) -> String {
        "valet\(version.major)\(version.minor).sock"
    }

    /// Makes sure a PHP version can serve Valet sites, like `valet use` does and
    /// PHP Monitor checks ("Ensuring that the Valet configuration is valid..."):
    /// - `php-fpm.d/valet-fpm.conf` from Valet's stub, listening on `valetXY.sock`
    /// - the default `www.conf` pool renamed to `www.conf.disabled-by-phpmon`
    /// - `conf.d/error_log.ini` and `conf.d/php-memory-limits.ini` from Valet's stubs
    /// Returns a description of each fix applied.
    @discardableResult
    public func ensureFpmConfiguration(for version: VersionNumber, user: String = NSUserName()) throws -> [String] {
        let fm = FileManager.default
        let etc = homebrew.etcDirectory(for: version)
        let stubs = "\(valetPackage)/cli/stubs"
        var fixes: [String] = []

        func fill(_ template: String) -> String {
            template
                .replacingOccurrences(of: "VALET_USER", with: user)
                .replacingOccurrences(of: "VALET_HOME_PATH", with: configDirectory)
                .replacingOccurrences(of: "valet.sock", with: Self.socketName(for: version))
        }

        let pool = "\(etc)/php-fpm.d/valet-fpm.conf"
        if !fm.fileExists(atPath: pool) {
            let stub = "\(stubs)/etc-phpfpm-valet.conf"
            guard let template = try? String(contentsOfFile: stub, encoding: .utf8) else {
                throw ValetError.stubMissing(stub)
            }
            try fm.createDirectory(atPath: "\(etc)/php-fpm.d", withIntermediateDirectories: true)
            try fill(template).write(toFile: pool, atomically: true, encoding: .utf8)
            fixes.append("Created \(pool)")
        }

        let www = "\(etc)/php-fpm.d/www.conf"
        let disabled = www + ".disabled-by-phpmon"
        if fm.fileExists(atPath: www) {
            if fm.fileExists(atPath: disabled) { try fm.removeItem(atPath: disabled) }
            try fm.moveItem(atPath: www, toPath: disabled)
            fixes.append("Disabled default pool \(www)")
        }

        for (stubName, target) in [("etc-phpfpm-error_log.ini", "error_log.ini"),
                                   ("php-memory-limits.ini", "php-memory-limits.ini")] {
            let path = "\(etc)/conf.d/\(target)"
            if !fm.fileExists(atPath: path),
               let template = try? String(contentsOfFile: "\(stubs)/\(stubName)", encoding: .utf8) {
                try fm.createDirectory(atPath: "\(etc)/conf.d", withIntermediateDirectories: true)
                try fill(template).write(toFile: path, atomically: true, encoding: .utf8)
                fixes.append("Created \(path)")
            }
        }
        return fixes
    }

    /// `ln -sF ~/.config/valet/valetXY.sock ~/.config/valet/valet.sock`
    /// (the exact command string is in PHP Monitor's binary).
    public func linkSocket(for version: VersionNumber) throws {
        let fm = FileManager.default
        let link = "\(configDirectory)/valet.sock"
        if (try? fm.destinationOfSymbolicLink(atPath: link)) != nil || fm.fileExists(atPath: link) {
            try fm.removeItem(atPath: link)
        }
        try fm.createSymbolicLink(atPath: link, withDestinationPath: "\(configDirectory)/\(Self.socketName(for: version))")
    }

    // MARK: Commands

    /// Runs a Valet command as root without a password prompt, matching the
    /// sudoers rule `valet trust` installs (`/opt/homebrew/bin/valet *`).
    /// `USER` is passed so Valet still acts for you, like Valet's own wrapper does.
    @discardableResult
    public func run(_ arguments: String) async throws -> ShellResult {
        let valetBin = "\(homebrew.prefix)/bin/valet"
        let command = FileManager.default.isExecutableFile(atPath: valetBin)
            ? "sudo -n USER=\(shellQuote(NSUserName())) --preserve-env \(valetBin) \(arguments)"
            : "valet \(arguments)"
        let result = try await homebrew.shell.run(command)
        guard result.succeeded else {
            throw BrewError.failed(command: "valet \(arguments)", output: result.stderr + result.stdout)
        }
        return result
    }

    public func secure(_ site: ValetSite) async throws { try await run("secure \(shellQuote(site.name))") }
    public func unsecure(_ site: ValetSite) async throws { try await run("unsecure \(shellQuote(site.name))") }
    public func isolate(_ site: ValetSite, formula: String) async throws {
        try await run("isolate \(shellQuote(formula)) --site=\(shellQuote(site.name))")
    }
    public func unisolate(_ site: ValetSite) async throws { try await run("unisolate --site=\(shellQuote(site.name))") }
}
