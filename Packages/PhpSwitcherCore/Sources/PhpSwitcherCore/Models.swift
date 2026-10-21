import Foundation

/// A PHP version like 8.3 or 8.3.12.
public struct VersionNumber: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int?

    public init(major: Int, minor: Int, patch: Int? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Finds the first `X.Y[.Z]` in a string, e.g. in `php -v` or `php-config --version` output.
    public static func parse(_ text: String) -> VersionNumber? {
        let regex = try! NSRegularExpression(pattern: #"(\d+)\.(\d+)(?:\.(\d+))?"#)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        func group(_ i: Int) -> Int? {
            guard let r = Range(match.range(at: i), in: text) else { return nil }
            return Int(text[r])
        }
        guard let major = group(1), let minor = group(2) else { return nil }
        return VersionNumber(major: major, minor: minor, patch: group(3))
    }

    /// "8.3" — what users pick in the menu.
    public var short: String { "\(major).\(minor)" }

    public var description: String { patch.map { "\(short).\($0)" } ?? short }

    public static func < (a: VersionNumber, b: VersionNumber) -> Bool {
        (a.major, a.minor, a.patch ?? 0) < (b.major, b.minor, b.patch ?? 0)
    }

    /// Same major.minor, ignoring patch.
    public func sameMinor(as other: VersionNumber) -> Bool {
        major == other.major && minor == other.minor
    }
}

/// One installed Homebrew PHP formula (`php` or `php@X.Y`).
public struct PhpInstallation: Sendable, Hashable, Identifiable {
    public let formula: String
    public let version: VersionNumber

    public init(formula: String, version: VersionNumber) {
        self.formula = formula
        self.version = version
    }

    public var id: String { formula }

    /// `php` is Homebrew's "primary" formula (the newest release); `php@X.Y` are versioned.
    public var isPrimaryFormula: Bool { formula == "php" }

    /// Formula names PHP Monitor accepts: `php` or `php@X.Y` (its regex is `^php@[0-9]+\.[0-9]+$`).
    public static func isPhpFormulaName(_ name: String) -> Bool {
        name.range(of: #"^php(@[0-9]+\.[0-9]+)?$"#, options: .regularExpression) != nil
    }
}

/// What is linked right now, read from where `<prefix>/bin/php` points.
public struct ActivePhp: Sendable, Equatable {
    public let formula: String
    public let version: VersionNumber

    public init(formula: String, version: VersionNumber) {
        self.formula = formula
        self.version = version
    }

    /// Parses a resolved path like `/opt/homebrew/Cellar/php@8.4/8.4.25/bin/php`.
    public static func fromCellarPath(_ path: String) -> ActivePhp? {
        let parts = path.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(of: "Cellar"), i + 2 < parts.count else { return nil }
        let formula = parts[i + 1]
        guard PhpInstallation.isPhpFormulaName(formula),
              let version = VersionNumber.parse(parts[i + 2]) else { return nil }
        return ActivePhp(formula: formula, version: version)
    }
}
