import Foundation

/// Persists the service list as JSON, guarded by an flock()'d lock file and
/// with a backup copy — the same safeguards DBngin has around DBEngines.plist
/// (DBEngines.lock, DBEngines.backup.plist).
public final class ServiceStore: @unchecked Sendable {
    public let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    public func load() throws -> [Service] {
        try withLock { try readUnlocked() }
    }

    /// Read-modify-write under the lock so the CLI and menu-bar app can't clobber each other.
    @discardableResult
    public func update<T>(_ body: (inout [Service]) throws -> T) throws -> T {
        try withLock {
            var services = try readUnlocked()
            let result = try body(&services)
            try writeUnlocked(services)
            return result
        }
    }

    private func readUnlocked() throws -> [Service] {
        let fm = FileManager.default
        let decoder = JSONDecoder()
        if fm.fileExists(atPath: paths.serviceList.path) {
            do {
                return try decoder.decode([Service].self, from: Data(contentsOf: paths.serviceList))
            } catch {
                // Damaged list: keep a copy, fall back to backup.
                let damaged = paths.dataDir.appendingPathComponent("services.damaged-\(Int(Date().timeIntervalSince1970)).json")
                try? fm.copyItem(at: paths.serviceList, to: damaged)
            }
        }
        if fm.fileExists(atPath: paths.serviceListBackup.path) {
            return try decoder.decode([Service].self, from: Data(contentsOf: paths.serviceListBackup))
        }
        return []
    }

    private func writeUnlocked(_ services: [Service]) throws {
        let fm = FileManager.default
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(services)
        if fm.fileExists(atPath: paths.serviceList.path) {
            try? fm.removeItem(at: paths.serviceListBackup)
            try? fm.copyItem(at: paths.serviceList, to: paths.serviceListBackup)
        }
        try data.write(to: paths.serviceList, options: .atomic)
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: paths.dataDir, withIntermediateDirectories: true)
        let fd = open(paths.lockFile.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
