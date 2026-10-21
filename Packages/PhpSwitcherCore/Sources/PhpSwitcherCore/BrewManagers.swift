import Foundation

public enum BrewError: Error, LocalizedError {
    case failed(command: String, output: String)

    public var errorDescription: String? {
        switch self {
        case .failed(let command, let output):
            let tail = output.split(separator: "\n").suffix(15).joined(separator: "\n")
            return "Command failed: \(command)\n\n\(tail)"
        }
    }
}

extension Homebrew {
    /// Runs a brew command that installs/removes things, with PHP Monitor's
    /// HOMEBREW_NO_* exports and a longer timeout.
    func modify(_ arguments: String, timeout: TimeInterval = 900) async throws {
        let command = "\(brewInstallEnvironment)\(brew) \(arguments)"
        let result = try await shell.run(command, timeout: timeout)
        guard result.succeeded else {
            throw BrewError.failed(command: "brew \(arguments)", output: result.stderr + result.stdout)
        }
    }
}

// MARK: - Extension manager

/// A PHP extension formula from the `shivammathur/extensions` tap, e.g. `xdebug@8.4`.
public struct BrewExtension: Sendable, Hashable, Identifiable {
    public let name: String
    public let phpVersion: String
    public let installed: Bool

    public var formula: String { "\(name)@\(phpVersion)" }
    public var tapFormula: String { "shivammathur/extensions/\(formula)" }
    public var id: String { formula }
}

/// PHP Monitor's Extension Manager (`BrewPhpExtension`, `InstallPhpExtensionCommand`,
/// `RemovePhpExtensionCommand`). It lists formulae from the tap folder using the
/// regex `(\w+)@(\d+\.\d+)\.rb` and installs `shivammathur/extensions/<name>@<version>`.
public struct ExtensionManager: Sendable {
    public let homebrew: Homebrew

    public init(homebrew: Homebrew) {
        self.homebrew = homebrew
    }

    public static let tap = "shivammathur/extensions"

    public var tapFormulaDirectory: String {
        "\(homebrew.prefix)/Library/Taps/shivammathur/homebrew-extensions/Formula"
    }

    public var isTapInstalled: Bool {
        FileManager.default.fileExists(atPath: tapFormulaDirectory)
    }

    public func available(for version: VersionNumber) -> [BrewExtension] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: tapFormulaDirectory)) ?? []
        return Self.parseFormulaFiles(files, version: version.short).map { name in
            BrewExtension(
                name: name,
                phpVersion: version.short,
                installed: FileManager.default.fileExists(atPath: "\(homebrew.prefix)/opt/\(name)@\(version.short)")
            )
        }
    }

    /// `["xdebug@8.4.rb", "redis@8.3.rb"]` + "8.4" → `["xdebug"]`
    public static func parseFormulaFiles(_ files: [String], version: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"^(\w+)@(\d+\.\d+)\.rb$"#)
        return files.compactMap { file -> String? in
            let range = NSRange(file.startIndex..., in: file)
            guard let match = regex.firstMatch(in: file, range: range),
                  let name = Range(match.range(at: 1), in: file),
                  let ver = Range(match.range(at: 2), in: file),
                  file[ver] == version else { return nil }
            return String(file[name])
        }.sorted()
    }

    public func installTap() async throws {
        try await homebrew.modify("tap \(Self.tap)")
    }

    public func install(_ ext: BrewExtension) async throws {
        try await homebrew.modify("install \(ext.tapFormula)")
    }

    /// `brew remove … --force --ignore-dependencies`, then deletes the .ini files
    /// in `conf.d` that load it ("Purging that .ini file" in PHP Monitor).
    /// Returns the .ini files that were removed.
    @discardableResult
    public func remove(_ ext: BrewExtension) async throws -> [String] {
        try await homebrew.modify("remove \(ext.formula) --force --ignore-dependencies", timeout: 300)

        let confD = "\(homebrew.prefix)/etc/php/\(ext.phpVersion)/conf.d"
        let marker = "/opt/\(ext.formula)/"
        var purged: [String] = []
        for file in (try? FileManager.default.contentsOfDirectory(atPath: confD)) ?? [] where file.hasSuffix(".ini") {
            let path = "\(confD)/\(file)"
            if let contents = try? String(contentsOfFile: path, encoding: .utf8), contents.contains(marker) {
                try FileManager.default.removeItem(atPath: path)
                purged.append(path)
            }
        }
        return purged
    }
}

// MARK: - PHP version manager

public struct PhpFormulaStatus: Sendable, Hashable, Identifiable {
    public let formula: String   // php@8.3
    public let version: String   // 8.3
    public let installed: Bool
    public let outdated: Bool

    public var id: String { formula }
}

/// PHP Monitor's "PHP Version Manager" (`ModifyPhpVersionCommand`,
/// `BrewPhpFormulaeHandler`): install, upgrade and remove PHP versions from the
/// `shivammathur/php` tap, using `brew outdated --json --formulae` for updates.
public struct PhpVersionManager: Sendable {
    public let homebrew: Homebrew

    public init(homebrew: Homebrew) {
        self.homebrew = homebrew
    }

    public static let tap = "shivammathur/php"

    public var tapFormulaDirectory: String {
        "\(homebrew.prefix)/Library/Taps/shivammathur/homebrew-php/Formula"
    }

    /// All `php@X.Y` formulae in the tap, newest first, merged with what is installed.
    public func formulae(installed: [PhpInstallation], outdated: Set<String>) -> [PhpFormulaStatus] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: tapFormulaDirectory)) ?? []
        var versions = Set(files.compactMap { file -> String? in
            guard file.range(of: #"^php@\d+\.\d+\.rb$"#, options: .regularExpression) != nil else { return nil }
            return String(file.dropFirst(4).dropLast(3))
        })
        for item in installed { versions.insert(item.version.short) }

        return versions
            .compactMap { VersionNumber.parse($0) }
            .sorted(by: >)
            .map { version in
                let match = installed.first { $0.version.sameMinor(as: version) }
                let formula = match?.formula ?? "php@\(version.short)"
                return PhpFormulaStatus(
                    formula: formula,
                    version: version.short,
                    installed: match != nil,
                    outdated: outdated.contains(formula)
                )
            }
    }

    /// Installed PHP formulae with a newer version available (local data, no `brew update`).
    public func outdated() async -> Set<String> {
        guard let result = try? await homebrew.brew("outdated --json --formulae"), result.succeeded else { return [] }
        return Self.parseOutdated(result.stdout)
    }

    public static func parseOutdated(_ json: String) -> Set<String> {
        struct Response: Decodable { struct Formula: Decodable { let name: String }; let formulae: [Formula] }
        guard let data = json.data(using: .utf8),
              let response = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return Set(response.formulae
            .map { ($0.name as NSString).lastPathComponent }
            .filter(PhpInstallation.isPhpFormulaName))
    }

    public func install(_ formula: String) async throws {
        let name = formula == "php" ? "php" : "\(Self.tap)/\(formula)"
        try await homebrew.modify("install \(name)")
    }

    public func upgrade(_ formula: String) async throws {
        try await homebrew.modify("upgrade \(formula)")
    }

    public func uninstall(_ formula: String) async throws {
        try await homebrew.modify("uninstall \(formula) --force --ignore-dependencies", timeout: 300)
    }
}

// MARK: - Composer

/// "Update global dependencies" from PHP Monitor's menu.
public struct Composer: Sendable {
    public let homebrew: Homebrew

    public init(homebrew: Homebrew) {
        self.homebrew = homebrew
    }

    public var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: "\(homebrew.prefix)/bin/composer")
    }

    public func globalUpdate() async throws -> String {
        let command = "\(homebrew.prefix)/bin/composer global update --no-interaction 2>&1"
        let result = try await homebrew.shell.run(command, timeout: 900)
        guard result.succeeded else { throw BrewError.failed(command: "composer global update", output: result.stdout) }
        return result.stdout
    }
}
