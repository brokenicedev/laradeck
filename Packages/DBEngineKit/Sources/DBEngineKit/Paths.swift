import Foundation

/// Where everything lives on disk:
///   <root>/Data/services.json      – the service list
///   <root>/Engines/<kind>/<uuid>/  – one data folder per service, with its launchd plist and logs
public struct Paths: Sendable {
    public let root: URL
    /// Prefix for launchd job labels.
    public let label: String

    public static let defaultLabel = "it.brokenice.laradeck.db"

    public init(root: URL? = nil, label: String = Paths.defaultLabel) {
        self.label = label
        if let root {
            self.root = root
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = support.appendingPathComponent("Laradeck/Databases", isDirectory: true)
        }
    }

    public var dataDir: URL { root.appendingPathComponent("Data", isDirectory: true) }
    public var serviceList: URL { dataDir.appendingPathComponent("services.json") }
    public var serviceListBackup: URL { dataDir.appendingPathComponent("services.backup.json") }
    public var lockFile: URL { dataDir.appendingPathComponent("services.lock") }
    public var enginesDir: URL { root.appendingPathComponent("Engines", isDirectory: true) }

    public func dataPath(for kind: EngineKind, id: UUID) -> URL {
        enginesDir.appendingPathComponent(kind.rawValue, isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }
}
