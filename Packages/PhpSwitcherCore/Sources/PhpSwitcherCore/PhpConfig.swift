import Foundation

public enum ConfigError: Error, LocalizedError {
    case unreadable(String)
    case invalidValue(String)
    case xdebugModeNotFound
    case phpInfoFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path): return "Could not read the PHP configuration file at: \(path)"
        case .invalidValue(let value): return "“\(value)” is not a valid value. Use for example 256M, 1G or -1."
        case .xdebugModeNotFound: return "xdebug.mode could not be found in any .ini file, and Xdebug is not enabled."
        case .phpInfoFailed(let output): return "Could not generate phpinfo():\n\(output)"
        }
    }
}

/// An `extension=…so` or `zend_extension=…so` line in an .ini file.
public struct PhpExtension: Sendable, Hashable, Identifiable {
    public let name: String
    public let iniFile: String
    public let line: String
    public let enabled: Bool

    public var id: String { "\(iniFile)|\(line)" }

    /// The exact regex from PHP Monitor's `PhpExtension.swift`.
    static let regex = try! NSRegularExpression(
        pattern: #"^(extension|zend_extension|;(\s?)extension|;(\s?)zend_extension)(\s?)(=)(\s?)(?<name>["]?(?:\/?.\/?)+(?:\.so)"?)$"#
    )

    public static func parse(contents: String, path: String) -> [PhpExtension] {
        contents.components(separatedBy: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let nameRange = Range(match.range(withName: "name"), in: line) else { return nil }
            let file = line[nameRange].replacingOccurrences(of: "\"", with: "")
            let name = (file as NSString).lastPathComponent.replacingOccurrences(of: ".so", with: "")
            return PhpExtension(name: name, iniFile: path, line: line, enabled: !line.hasPrefix(";"))
        }
    }

    /// The same line with the leading `;` added (disable) or removed (enable).
    public var toggledLine: String {
        if enabled { return ";" + line }
        var result = line
        result.removeFirst()
        return result.trimmingCharacters(in: .whitespaces)
    }
}

/// Memory/upload limits shown in PHP Monitor's menu.
public struct PhpLimits: Sendable, Equatable {
    public let memoryLimit: String
    public let postMaxSize: String
    public let uploadMaxFilesize: String

    public static let keys = ["memory_limit", "post_max_size", "upload_max_filesize"]
}

/// Reads and edits the .ini files of a PHP version.
public struct PhpConfig: Sendable {
    public let homebrew: Homebrew
    public let phpBinary: String
    public let etcDirectory: String

    public init(homebrew: Homebrew, phpBinary: String, etcDirectory: String) {
        self.homebrew = homebrew
        self.phpBinary = phpBinary
        self.etcDirectory = etcDirectory
    }

    public var phpIni: String { "\(etcDirectory)/php.ini" }
    public var confD: String { "\(etcDirectory)/conf.d" }

    // MARK: Ini files

    /// Loaded .ini files, in load order. PHP Monitor runs
    /// `php --ini | grep -E -o '(/[^ ]+\.ini)'`; the regex is done in Swift here.
    public func iniFiles() async -> [String] {
        guard let result = try? await homebrew.shell.run("\(shellQuote(phpBinary)) --ini"), result.succeeded else {
            return [phpIni]
        }
        return Self.parseIniList(result.stdout)
    }

    public static func parseIniList(_ output: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"(/[^ ,\n]+\.ini)"#)
        let range = NSRange(output.startIndex..., in: output)
        var seen = Set<String>()
        return regex.matches(in: output, range: range).compactMap {
            Range($0.range(at: 1), in: output).map { String(output[$0]) }
        }.filter { seen.insert($0).inserted }
    }

    // MARK: Extensions

    public func extensions() async -> [PhpExtension] {
        await iniFiles().flatMap { path -> [PhpExtension] in
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
            return PhpExtension.parse(contents: contents, path: path)
        }
    }

    /// Comments or uncomments the extension's line in place.
    public func toggle(_ ext: PhpExtension) throws {
        guard let contents = try? String(contentsOfFile: ext.iniFile, encoding: .utf8) else {
            throw ConfigError.unreadable(ext.iniFile)
        }
        let updated = contents.components(separatedBy: "\n").map { raw in
            raw.trimmingCharacters(in: .whitespaces) == ext.line ? ext.toggledLine : raw
        }.joined(separator: "\n")
        try updated.write(toFile: ext.iniFile, atomically: true, encoding: .utf8)
    }

    // MARK: Limits

    public func limits() async -> PhpLimits? {
        let code = #"echo ini_get("memory_limit"),"|",ini_get("post_max_size"),"|",ini_get("upload_max_filesize");"#
        guard let result = try? await homebrew.shell.run("\(shellQuote(phpBinary)) -r \(shellQuote(code))"),
              result.succeeded else { return nil }
        let parts = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
        guard parts.count == 3 else { return nil }
        return PhpLimits(memoryLimit: parts[0], postMaxSize: parts[1], uploadMaxFilesize: parts[2])
    }

    /// Same idea as PHP Monitor's `^([0-9]*)(K|M|G|)$` check, plus `-1` (unlimited).
    public static func isValidSize(_ value: String) -> Bool {
        value == "-1" || value.range(of: #"^[0-9]+[KMG]?$"#, options: .regularExpression) != nil
    }

    /// Sets `key = value` in the last loaded .ini file that defines it (that one wins).
    /// If no file defines it, adds it to `conf.d/php-memory-limits.ini`.
    public func set(_ key: String, to value: String) async throws {
        guard Self.isValidSize(value) else { throw ConfigError.invalidValue(value) }
        let files = await iniFiles()
        let keyPattern = "^\\s*\(NSRegularExpression.escapedPattern(for: key))\\s*="
        for path in files.reversed() {
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            var lines = contents.components(separatedBy: "\n")
            if let index = lines.lastIndex(where: { $0.range(of: keyPattern, options: .regularExpression) != nil }) {
                lines[index] = "\(key) = \(value)"
                try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
                return
            }
        }
        let fallback = "\(confD)/php-memory-limits.ini"
        let existing = (try? String(contentsOfFile: fallback, encoding: .utf8)) ?? ""
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        try (existing + separator + "\(key) = \(value)\n").write(toFile: fallback, atomically: true, encoding: .utf8)
    }

    // MARK: Xdebug

    /// Modes listed in PHP Monitor's binary (`off`, `develop`, `coverage`, `debug`, `gcstats`, `profile`, `trace`).
    public static let xdebugModes = ["off", "develop", "debug", "coverage", "profile", "trace", "gcstats"]

    static let xdebugModeLine = #"^\s*;?\s*xdebug\.mode\s*="#

    public func xdebugMode() async -> String? {
        for path in await iniFiles().reversed() {
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in contents.components(separatedBy: "\n").reversed()
            where line.range(of: Self.xdebugModeLine, options: .regularExpression) != nil && !line.hasPrefix(";") {
                return line.components(separatedBy: "=").last?
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "\"", with: "")
            }
        }
        return nil
    }

    /// Replaces `xdebug.mode = …`. If there is none, PHP Monitor aborts and warns
    /// ("Missing configuration file for `xdebug.mode`"); here we add it to the
    /// .ini file that loads Xdebug.
    public func setXdebugMode(_ mode: String) async throws {
        let files = await iniFiles()
        for path in files.reversed() {
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            var lines = contents.components(separatedBy: "\n")
            if let index = lines.lastIndex(where: { $0.range(of: Self.xdebugModeLine, options: .regularExpression) != nil }) {
                lines[index] = "xdebug.mode = \(mode)"
                try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
                return
            }
        }
        for path in files {
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            if PhpExtension.parse(contents: contents, path: path).contains(where: { $0.name == "xdebug" && $0.enabled }) {
                let separator = contents.hasSuffix("\n") ? "" : "\n"
                try (contents + separator + "xdebug.mode = \(mode)\n").write(toFile: path, atomically: true, encoding: .utf8)
                return
            }
        }
        throw ConfigError.xdebugModeNotFound
    }

    // MARK: phpinfo()

    /// PHP Monitor runs `php-cgi -q /tmp/phpmon_phpinfo.php > /tmp/phpmon_phpinfo.html`
    /// and opens the HTML file. Same approach here.
    public func phpInfoPage(phpCgi: String) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let script = dir.appendingPathComponent("phpmonit_phpinfo.php")
        let html = dir.appendingPathComponent("phpmonit_phpinfo.html")
        try "<?php phpinfo();".write(to: script, atomically: true, encoding: .utf8)
        let result = try await homebrew.shell.run(
            "\(shellQuote(phpCgi)) -q \(shellQuote(script.path)) > \(shellQuote(html.path))"
        )
        guard result.succeeded else { throw ConfigError.phpInfoFailed(result.stderr) }
        return html
    }

    /// Path from `error_log=…` (Valet puts it in `conf.d/error_log.ini`).
    public func errorLogPath() async -> String? {
        for path in await iniFiles().reversed() {
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in contents.components(separatedBy: "\n").reversed()
            where line.range(of: #"^\s*error_log\s*="#, options: .regularExpression) != nil {
                let value = line.components(separatedBy: "=").dropFirst().joined(separator: "=")
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "\"", with: "")
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}
