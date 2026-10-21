import Foundation

/// One configured database server. Equivalent of an entry in DBngin's DBEngines.plist.
public struct Service: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: EngineKind
    public var version: String
    /// Folder that contains `bin/` for this engine.
    public var binariesPath: String
    /// Data folder: database files, logs, pid file and the launchd plist.
    public var dataPath: String
    public var port: Int
    /// Start this service when DBMenu launches (or `dbctl autostart`).
    public var autoStart: Bool
    /// Set when the server listens on the LAN; nil = localhost only.
    public var networkShare: NetworkShare?

    public init(id: UUID = UUID(), name: String, kind: EngineKind, version: String,
                binariesPath: String, dataPath: String, port: Int, autoStart: Bool = false,
                networkShare: NetworkShare? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.version = version
        self.binariesPath = binariesPath
        self.dataPath = dataPath
        self.port = port
        self.autoStart = autoStart
        self.networkShare = networkShare
    }

    public var isShared: Bool { networkShare != nil }

    /// launchd label. DBngin uses "com.tinyapp.DBngin.<server>-<UUID>".
    public func launchdLabel(prefix: String) -> String {
        "\(prefix).\(kind.serverBinary)-\(id.uuidString)"
    }

    public var binaryURL: URL { URL(fileURLWithPath: binariesPath).appendingPathComponent("bin") }
    public var dataURL: URL { URL(fileURLWithPath: dataPath) }

    public var connectionURL: String { kind.connectionURL(port: port, name: name) }
}
