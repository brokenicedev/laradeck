import Foundation

/// Creates a unique temporary directory for file-based detector tests.
enum TemporaryDirectory {
    static func make() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("laradeck-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
