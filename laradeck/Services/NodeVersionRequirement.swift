import Foundation

/// A Node.js version like `v20.19.2`.
nonisolated struct NodeVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    var major: Int
    var minor: Int
    var patch: Int

    init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses a full version ("v20.19.2", "20.19.2"). Missing parts count as 0.
    init?(_ text: String) {
        guard let parts = NodeRequirement.numericParts(text), !parts.isEmpty else { return nil }
        self.init(major: parts[0], minor: parts.count > 1 ? parts[1] : 0, patch: parts.count > 2 ? parts[2] : 0)
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (a: NodeVersion, b: NodeVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

/// Where a project's Node requirement was read from.
nonisolated enum NodeRequirementSource: String, Sendable {
    case nvmrc = ".nvmrc"
    case nodeVersionFile = ".node-version"
    case engines = "package.json engines.node"
    case volta = "package.json volta.node"
}

/// A Node version requirement: an `.nvmrc` value (`20`, `v20.19.2`, `lts/*`, `lts/iron`, `node`)
/// or an npm semver range (`^20.19 || >=22.12`, `>=18`, `20.x`, `18 - 20`, `~20.1`).
nonisolated struct NodeRequirement: Sendable, Equatable, CustomStringConvertible {
    /// Any of these alternatives (`||`); each is a list of comparators that must all hold.
    private let alternatives: [[Comparator]]
    /// `lts/*` and friends: only even (LTS) majors qualify.
    private let ltsOnly: Bool
    let description: String

    private struct Comparator: Equatable {
        enum Op { case lt, lte, gt, gte, eq }
        var op: Op
        var version: NodeVersion

        func matches(_ v: NodeVersion) -> Bool {
            switch op {
            case .lt: return v < version
            case .lte: return v <= version
            case .gt: return v > version
            case .gte: return v >= version
            case .eq: return v == version
            }
        }
    }

    /// LTS codenames used by `.nvmrc` (`lts/iron`).
    private static let ltsCodenames: [String: Int] = [
        "argon": 4, "boron": 6, "carbon": 8, "dubnium": 10, "erbium": 12, "fermium": 14,
        "gallium": 16, "hydrogen": 18, "iron": 20, "jod": 22, "krypton": 24,
    ]

    /// Returns nil when the text can't be understood (better no warning than a wrong one).
    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        description = trimmed

        // nvm aliases.
        if ["node", "stable", "latest", "current", "*", "x"].contains(lower) {
            alternatives = [[]]
            ltsOnly = false
            return
        }
        if lower.hasPrefix("lts/") {
            let name = String(lower.dropFirst(4))
            if name == "*" || name == "-1" || name.isEmpty {
                alternatives = [[]]
                ltsOnly = true
                return
            }
            guard let major = Self.ltsCodenames[name] else { return nil }
            alternatives = [Self.caret(NodeVersion(major: major), precision: 1)]
            ltsOnly = false
            return
        }

        var parsed: [[Comparator]] = []
        for alternative in trimmed.components(separatedBy: "||") {
            guard let comparators = Self.parseConjunction(alternative) else { return nil }
            parsed.append(comparators)
        }
        guard !parsed.isEmpty else { return nil }
        alternatives = parsed
        ltsOnly = false
    }

    func satisfies(_ version: NodeVersion) -> Bool {
        if ltsOnly, version.major % 2 != 0 || version.major < 4 { return false }
        return alternatives.contains { $0.allSatisfy { $0.matches(version) } }
    }

    /// The newest of `versions` that satisfies the requirement.
    func bestMatch(in versions: [NodeVersion]) -> NodeVersion? {
        versions.filter(satisfies).max()
    }

    /// What to pass to `nvm install` to get a fitting version ("20", "lts/*", "22.12.0"…).
    var installHint: String {
        let lower = description.lowercased()
        if lower.hasPrefix("lts/") || ["node", "stable", "latest"].contains(lower) { return description }
        // The highest lower bound across alternatives is a reasonable guess.
        let candidates = alternatives.compactMap { comparators -> NodeVersion? in
            comparators.filter { [.gte, .gt, .eq].contains($0.op) }.map(\.version).max()
        }
        if let best = candidates.max() {
            return best.minor == 0 && best.patch == 0 ? "\(best.major)" : best.description
        }
        return "node"
    }

    // MARK: Parsing

    private static func parseConjunction(_ text: String) -> [Comparator]? {
        let tokens = text.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        if tokens.isEmpty { return [] }
        // Hyphen range: "18 - 20.5"
        if tokens.count == 3, tokens[1] == "-",
           let low = partial(tokens[0]), let high = partial(tokens[2]) {
            var result = [Comparator(op: .gte, version: low.version)]
            result += upperBound(of: high, inclusive: true)
            return result
        }
        // ">= 18" written with a space.
        var merged: [String] = []
        for token in tokens {
            if let last = merged.last, ["<", "<=", ">", ">=", "="].contains(last) {
                merged[merged.count - 1] = last + token
            } else {
                merged.append(token)
            }
        }
        var result: [Comparator] = []
        for token in merged {
            guard let comparators = parseComparator(token) else { return nil }
            result += comparators
        }
        return result
    }

    private static func parseComparator(_ token: String) -> [Comparator]? {
        for (prefix, op) in [(">=", Comparator.Op.gte), ("<=", .lte), (">", .gt), ("<", .lt), ("=", .eq)] {
            guard token.hasPrefix(prefix) else { continue }
            guard let p = partial(String(token.dropFirst(prefix.count))) else { return nil }
            switch op {
            case .gte: return [Comparator(op: .gte, version: p.version)]
            case .lt: return [Comparator(op: .lt, version: p.version)]
            case .gt:
                // ">20" means ">=21.0.0"; ">20.1.2" is a plain greater-than.
                if p.precision < 3 { return upperBound(of: p, inclusive: true).map { Comparator(op: .gte, version: $0.version) } }
                return [Comparator(op: .gt, version: p.version)]
            case .lte:
                if p.precision < 3 { return upperBound(of: p, inclusive: true) }
                return [Comparator(op: .lte, version: p.version)]
            case .eq: return exact(p)
            }
        }
        if token.hasPrefix("^") {
            guard let p = partial(String(token.dropFirst())) else { return nil }
            return caret(p.version, precision: p.precision)
        }
        if token.hasPrefix("~") {
            guard let p = partial(String(token.dropFirst()).replacingOccurrences(of: ">", with: "")) else { return nil }
            var result = [Comparator(op: .gte, version: p.version)]
            let upper = p.precision >= 2
                ? NodeVersion(major: p.version.major, minor: p.version.minor + 1)
                : NodeVersion(major: p.version.major + 1)
            result.append(Comparator(op: .lt, version: upper))
            return result
        }
        if token == "*" || token.lowercased() == "x" { return [] }
        guard let p = partial(token) else { return nil }
        return exact(p)
    }

    /// "20" → 20.x, "20.1" → 20.1.x, "20.1.2" → exactly 20.1.2.
    private static func exact(_ p: Partial) -> [Comparator] {
        if p.precision >= 3 { return [Comparator(op: .eq, version: p.version)] }
        return [Comparator(op: .gte, version: p.version)] + upperBound(of: p, inclusive: true)
    }

    private static func caret(_ v: NodeVersion, precision: Int) -> [Comparator] {
        let upper: NodeVersion
        if v.major > 0 || precision == 1 {
            upper = NodeVersion(major: v.major + 1)
        } else if v.minor > 0 || precision == 2 {
            upper = NodeVersion(major: 0, minor: v.minor + 1)
        } else {
            upper = NodeVersion(major: 0, minor: 0, patch: v.patch + 1)
        }
        return [Comparator(op: .gte, version: v), Comparator(op: .lt, version: upper)]
    }

    /// Upper bound for a partial version used inclusively: "20" → <21.0.0, "20.5" → <20.6.0.
    private static func upperBound(of p: Partial, inclusive: Bool) -> [Comparator] {
        switch p.precision {
        case 1: return [Comparator(op: .lt, version: NodeVersion(major: p.version.major + 1))]
        case 2: return [Comparator(op: .lt, version: NodeVersion(major: p.version.major, minor: p.version.minor + 1))]
        default: return [Comparator(op: inclusive ? .lte : .lt, version: p.version)]
        }
    }

    private struct Partial {
        var version: NodeVersion
        /// How many parts were given (x/* parts don't count).
        var precision: Int
    }

    private static func partial(_ text: String) -> Partial? {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // Drop pre-release / build suffixes ("20.0.0-rc.1").
        if let dash = s.firstIndex(where: { $0 == "-" || $0 == "+" }) { s = String(s[..<dash]) }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            if ["x", "X", "*"].contains(part) { break }
            guard let n = Int(part) else { return nil }
            numbers.append(n)
        }
        if numbers.isEmpty { return nil }
        return Partial(
            version: NodeVersion(major: numbers[0],
                                 minor: numbers.count > 1 ? numbers[1] : 0,
                                 patch: numbers.count > 2 ? numbers[2] : 0),
            precision: numbers.count
        )
    }

    static func numericParts(_ text: String) -> [Int]? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") { s.removeFirst() }
        let parts = s.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }
    }
}

/// A project's Node requirement, read from (in order) `.nvmrc`, `.node-version`,
/// `package.json` `engines.node`, `package.json` `volta.node`.
nonisolated struct ProjectNodeRequirement: Sendable, Equatable {
    let requirement: NodeRequirement
    let source: NodeRequirementSource

    /// Sail projects run Node inside the container.
    static func read(for project: Project) -> ProjectNodeRequirement? {
        guard project.environment == .native else { return nil }
        return read(atPath: project.path)
    }

    static func read(atPath path: String) -> ProjectNodeRequirement? {
        let dir = URL(fileURLWithPath: path)
        for (file, source) in [(".nvmrc", NodeRequirementSource.nvmrc), (".node-version", .nodeVersionFile)] {
            if let text = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8),
               let requirement = fromVersionFile(text) {
                return ProjectNodeRequirement(requirement: requirement, source: source)
            }
        }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("package.json")) {
            return fromPackageJSON(data)
        }
        return nil
    }

    /// First non-comment line of `.nvmrc` / `.node-version`.
    static func fromVersionFile(_ text: String) -> NodeRequirement? {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }
        guard let line else { return nil }
        let value = line.split(separator: "#").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? line
        return NodeRequirement(value)
    }

    static func fromPackageJSON(_ data: Data) -> ProjectNodeRequirement? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let engines = json["engines"] as? [String: Any], let node = engines["node"] as? String,
           let requirement = NodeRequirement(node) {
            return ProjectNodeRequirement(requirement: requirement, source: .engines)
        }
        if let volta = json["volta"] as? [String: Any], let node = volta["node"] as? String,
           let requirement = NodeRequirement(node) {
            return ProjectNodeRequirement(requirement: requirement, source: .volta)
        }
        return nil
    }
}
