import Foundation

/// A folder with ready-to-use server binaries (contains bin/<server>).
public struct InstalledBinaries: Hashable, Identifiable, Sendable {
    public let kind: EngineKind
    public let version: String
    public let url: URL
    /// Homebrew formula name, if these binaries come from Homebrew.
    public let formula: String?

    public init(kind: EngineKind, version: String, url: URL, formula: String? = nil) {
        self.kind = kind
        self.version = version
        self.url = url
        self.formula = formula
    }

    public var id: String { url.path }
    public var source: String { formula.map { "Homebrew \($0)" } ?? "local" }
}

public enum BinaryLocator {
    /// Installed engine versions (Homebrew formulae).
    public static func installed(_ kind: EngineKind) -> [InstalledBinaries] {
        Homebrew.installed(kind)
    }

    public static func isValid(_ dir: URL, kind: EngineKind) -> Bool {
        FileManager.default.isExecutableFile(
            atPath: dir.appendingPathComponent("bin").appendingPathComponent(kind.serverBinary).path)
    }
}
