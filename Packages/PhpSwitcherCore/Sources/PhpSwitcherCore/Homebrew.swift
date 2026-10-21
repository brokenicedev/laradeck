import Foundation

/// Locates Homebrew and reads PHP state from it.
public struct Homebrew: Sendable {
    public let prefix: String
    public let shell: Shell

    public init(prefix: String, shell: Shell) {
        self.prefix = prefix
        self.shell = shell
    }

    /// PHP Monitor checks the same two prefixes (`/opt/homebrew`, `/usr/local`).
    public static func detectPrefix(fileManager: FileManager = .default) -> String? {
        ["/opt/homebrew", "/usr/local"].first {
            fileManager.isExecutableFile(atPath: "\($0)/bin/brew")
        }
    }

    public var brew: String { "\(prefix)/bin/brew" }

    /// Runs `brew <arguments>`.
    @discardableResult
    public func brew(_ arguments: String) async throws -> ShellResult {
        try await shell.run("\(brew) \(arguments)")
    }

    // MARK: - Discovery

    /// Installed PHP formulae, newest first.
    ///
    /// Scans `<prefix>/opt` for `php` / `php@X.Y`, keeps only kegs that have a
    /// `bin/php`, and asks each keg's `php-config --version` for its real version
    /// (PHP Monitor uses `<keg>/bin/php-config` for this too).
    public func installedVersions(fileManager: FileManager = .default) async -> [PhpInstallation] {
        let optDir = "\(prefix)/opt"
        let names = ((try? fileManager.contentsOfDirectory(atPath: optDir)) ?? [])
            .filter(PhpInstallation.isPhpFormulaName)

        var found: [PhpInstallation] = []
        for name in names {
            let keg = "\(optDir)/\(name)"
            guard fileManager.isExecutableFile(atPath: "\(keg)/bin/php") else { continue }

            var version: VersionNumber?
            if let result = try? await shell.run("'\(keg)/bin/php-config' --version"), result.succeeded {
                version = VersionNumber.parse(result.stdout)
            }
            // Fallback: the opt symlink points at ../Cellar/<formula>/<version>.
            if version == nil {
                let resolved = URL(fileURLWithPath: keg).resolvingSymlinksInPath().lastPathComponent
                version = VersionNumber.parse(resolved)
            }
            if let version {
                found.append(PhpInstallation(formula: name, version: version))
            }
        }
        return Self.deduplicate(found)
    }

    /// When `php` and `php@X.Y` are the same minor version, keep `php`: it is the
    /// primary formula (PHP Monitor logs "… is the primary formula, linking...").
    public static func deduplicate(_ list: [PhpInstallation]) -> [PhpInstallation] {
        var byMinor: [String: PhpInstallation] = [:]
        for item in list {
            if let existing = byMinor[item.version.short], existing.isPrimaryFormula { continue }
            byMinor[item.version.short] = item
        }
        return byMinor.values.sorted { $0.version > $1.version }
    }

    /// The linked PHP, read from where `<prefix>/bin/php` points.
    /// Returns nil if no PHP is linked.
    public func activePhp() async -> ActivePhp? {
        let link = "\(prefix)/bin/php"
        guard FileManager.default.fileExists(atPath: link) else { return nil }
        let resolved = URL(fileURLWithPath: link).resolvingSymlinksInPath().path
        if let active = ActivePhp.fromCellarPath(resolved) {
            return active
        }
        // Not a Cellar symlink; ask the binary itself.
        if let result = try? await shell.run("'\(link)' -r 'echo PHP_VERSION;'"),
           result.succeeded, let version = VersionNumber.parse(result.stdout) {
            return ActivePhp(formula: "php", version: version)
        }
        return nil
    }

    /// `<prefix>/bin/php`, the binary that is linked right now.
    public var linkedPhpBinary: String { "\(prefix)/bin/php" }

    /// Config directory for a version, e.g. `/opt/homebrew/etc/php/8.4`.
    public func etcDirectory(for version: VersionNumber) -> String {
        "\(prefix)/etc/php/\(version.short)"
    }
}
