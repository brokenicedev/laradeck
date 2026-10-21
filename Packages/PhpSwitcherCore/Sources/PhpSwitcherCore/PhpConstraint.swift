import Foundation

/// A Composer version constraint for `require.php`, e.g. `^8.2`, `~8.1.0`, `>=8.1 <8.4`,
/// `8.2.*`, `^8.1 || ^8.2`.
///
/// Follows Composer's rules, with one deliberate difference: a bare `8.2` means `8.2.*`
/// (Composer would read it as exactly 8.2.0, which nobody means for PHP itself).
public struct PhpConstraint: Sendable, Equatable, CustomStringConvertible {
    /// Any of these alternatives (`||`); each is a list of ranges that must all hold.
    let alternatives: [[Range]]
    public let description: String

    struct Range: Sendable, Equatable {
        var lower: Bound?
        var upper: Bound?
        var excluded: Version?

        func contains(_ v: Version) -> Bool {
            if let lower, lower.inclusive ? v < lower.version : v <= lower.version { return false }
            if let upper, upper.inclusive ? v > upper.version : v >= upper.version { return false }
            if let excluded, v == excluded { return false }
            return true
        }
    }

    struct Bound: Sendable, Equatable {
        var version: Version
        var inclusive: Bool
    }

    struct Version: Sendable, Equatable, Comparable {
        var major: Int, minor: Int, patch: Int
        static func < (a: Version, b: Version) -> Bool {
            (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
    }

    /// Returns nil when the string can't be understood (better no warning than a wrong one).
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var alternatives: [[Range]] = []
        for alternative in trimmed.components(separatedBy: "|") {
            let part = alternative.trimmingCharacters(in: .whitespaces)
            if part.isEmpty { continue } // the second "|" of "||"
            guard let ranges = Self.parseConjunction(part) else { return nil }
            alternatives.append(ranges)
        }
        guard !alternatives.isEmpty else { return nil }
        self.alternatives = alternatives
        self.description = trimmed
    }

    public func satisfies(_ version: VersionNumber) -> Bool {
        let v = Version(major: version.major, minor: version.minor, patch: version.patch ?? 0)
        // An unknown patch (e.g. "8.2") satisfies if any patch of that minor could.
        if version.patch == nil {
            return alternatives.contains { ranges in
                ranges.allSatisfy { range in
                    range.contains(v) || range.contains(Version(major: v.major, minor: v.minor, patch: 999))
                }
            }
        }
        return alternatives.contains { $0.allSatisfy { $0.contains(v) } }
    }

    /// The newest installed PHP that satisfies the constraint.
    public func bestMatch(in installed: [PhpInstallation]) -> PhpInstallation? {
        installed.filter { satisfies($0.version) }.max { $0.version < $1.version }
    }

    // MARK: Parsing

    /// "a b" and "a, b" are AND; also handles "8.1 - 8.3" hyphen ranges.
    private static func parseConjunction(_ text: String) -> [Range]? {
        let tokens = text.replacingOccurrences(of: ",", with: " ")
            .split(separator: " ").map(String.init)
        if tokens.count == 3, tokens[1] == "-",
           let low = version(tokens[0]), let high = version(tokens[2]) {
            return [Range(lower: Bound(version: low.version, inclusive: true),
                          upper: high.count == 3
                              ? Bound(version: high.version, inclusive: true)
                              : Bound(version: next(high.version, at: high.count), inclusive: false))]
        }
        var ranges: [Range] = []
        var pendingOperator: String?
        for token in tokens {
            // ">= 8.1" with a space between operator and version.
            if ["<", "<=", ">", ">=", "=", "==", "!=", "^", "~"].contains(token) {
                pendingOperator = token
                continue
            }
            let atom = (pendingOperator ?? "") + token
            pendingOperator = nil
            guard let range = parseAtom(atom) else { return nil }
            ranges.append(range)
        }
        return ranges.isEmpty ? nil : ranges
    }

    private static func parseAtom(_ raw: String) -> Range? {
        var atom = raw
        if let at = atom.firstIndex(of: "@") { atom = String(atom[..<at]) } // stability flags
        if atom == "*" { return Range() }

        for op in [">=", "<=", "!=", "==", ">", "<", "=", "^", "~"] where atom.hasPrefix(op) {
            guard let v = version(String(atom.dropFirst(op.count))) else { return nil }
            switch op {
            case ">=": return Range(lower: Bound(version: v.version, inclusive: true))
            case ">": return Range(lower: Bound(version: v.version, inclusive: false))
            case "<=": return Range(upper: Bound(version: v.version, inclusive: true))
            case "<": return Range(upper: Bound(version: v.version, inclusive: false))
            case "!=": return Range(excluded: v.version)
            case "=", "==": return exact(v)
            case "^":
                // ^8.2 → >=8.2 <9.0 ; ^0.3 → >=0.3 <0.4
                let upper = v.version.major > 0
                    ? Version(major: v.version.major + 1, minor: 0, patch: 0)
                    : Version(major: 0, minor: v.version.minor + 1, patch: 0)
                return Range(lower: Bound(version: v.version, inclusive: true),
                             upper: Bound(version: upper, inclusive: false))
            case "~":
                // ~8.1 → >=8.1 <9.0 ; ~8.1.3 → >=8.1.3 <8.2.0
                let upper = v.count >= 3
                    ? Version(major: v.version.major, minor: v.version.minor + 1, patch: 0)
                    : Version(major: v.version.major + 1, minor: 0, patch: 0)
                return Range(lower: Bound(version: v.version, inclusive: true),
                             upper: Bound(version: upper, inclusive: false))
            default: return nil
            }
        }

        // Wildcards: 8.* / 8.2.* / 8.2.x
        let parts = atom.lowercased().split(separator: ".").map(String.init)
        if let last = parts.last, last == "*" || last == "x" {
            guard let v = version(parts.dropLast().joined(separator: ".")) else { return nil }
            return Range(lower: Bound(version: v.version, inclusive: true),
                         upper: Bound(version: next(v.version, at: v.count), inclusive: false))
        }
        guard let v = version(atom) else { return nil }
        return exact(v)
    }

    /// Bare "8.2" means any 8.2.x; "8.2.3" means exactly that.
    private static func exact(_ v: (version: Version, count: Int)) -> Range {
        if v.count >= 3 {
            return Range(lower: Bound(version: v.version, inclusive: true),
                         upper: Bound(version: v.version, inclusive: true))
        }
        return Range(lower: Bound(version: v.version, inclusive: true),
                     upper: Bound(version: next(v.version, at: v.count), inclusive: false))
    }

    /// First version after the given precision: 8 → 9.0.0, 8.2 → 8.3.0.
    private static func next(_ v: Version, at count: Int) -> Version {
        count <= 1
            ? Version(major: v.major + 1, minor: 0, patch: 0)
            : Version(major: v.major, minor: v.minor + 1, patch: 0)
    }

    /// "8", "8.2", "8.2.3", "v8.2" → version + how many parts were given.
    private static func version(_ text: String) -> (version: Version, count: Int)? {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") { t.removeFirst() }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        let numbers = parts.prefix(3).compactMap { Int($0) }
        guard numbers.count == min(parts.count, 3) else { return nil }
        return (Version(major: numbers[0],
                        minor: numbers.count > 1 ? numbers[1] : 0,
                        patch: numbers.count > 2 ? numbers[2] : 0),
                numbers.count)
    }
}
