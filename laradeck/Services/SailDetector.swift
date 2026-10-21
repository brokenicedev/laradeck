import Foundation

nonisolated enum SailDetector {
    private static let composeFileNames = ["docker-compose.yml", "compose.yaml", "compose.yml", "docker-compose.yaml"]

    static func hasComposeFile(at path: String) -> Bool {
        let fm = FileManager.default
        return composeFileNames.contains {
            fm.fileExists(atPath: (path as NSString).appendingPathComponent($0))
        }
    }

    /// A compose file is required either way — `vendor/bin/sail` on its own just means
    /// `laravel/sail` is (or was) a composer dependency, which is true of most fresh Laravel
    /// installs by default whether or not Sail is actually set up; it says nothing about whether
    /// there's anything for `sail up` to actually run.
    static func usesSail(at path: String) -> Bool {
        let fm = FileManager.default

        guard hasComposeFile(at: path) else { return false }

        let sailBinary = (path as NSString).appendingPathComponent("vendor/bin/sail")
        if fm.fileExists(atPath: sailBinary) {
            return true
        }

        guard let composer = LaravelDetector.readComposerJSON(at: path) else { return false }
        let require = (composer["require"] as? [String: Any])?.keys ?? Dictionary<String, Any>().keys
        let requireDev = (composer["require-dev"] as? [String: Any])?.keys ?? Dictionary<String, Any>().keys
        return Set(require).union(requireDev).contains("laravel/sail")
    }
}
