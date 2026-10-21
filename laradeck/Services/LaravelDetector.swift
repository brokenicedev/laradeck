import Foundation

nonisolated struct LaravelMetadata {
    var appName: String?
    var appURL: String?
    var appEnv: String?
    var appDebug: String?
    var laravelConstraint: String?
    var hasHorizon: Bool = false
    var hasReverb: Bool = false
    var hasSail: Bool = false
    /// Full parsed .env, with secret-looking keys (PASSWORD/SECRET/KEY/TOKEN) stripped —
    /// spec §45/§24: never surface credentials in the UI.
    var safeEnvironment: [String: String] = [:]
}

nonisolated enum LaravelDetector {
    private static let requiredEntries = ["artisan", "composer.json", "app", "bootstrap", "config"]

    static func isLaravelProject(at path: String) -> Bool {
        let fm = FileManager.default
        for entry in requiredEntries {
            let entryPath = (path as NSString).appendingPathComponent(entry)
            if !fm.fileExists(atPath: entryPath) {
                return false
            }
        }
        return true
    }

    static func detectMetadata(at path: String) -> LaravelMetadata {
        var metadata = LaravelMetadata()

        if let composer = readComposerJSON(at: path) {
            let require = (composer["require"] as? [String: Any])?.keys ?? Dictionary<String, Any>().keys
            let requireDev = (composer["require-dev"] as? [String: Any])?.keys ?? Dictionary<String, Any>().keys
            let allDeps = Set(require).union(requireDev)

            metadata.appName = composer["name"] as? String
            metadata.laravelConstraint = (composer["require"] as? [String: Any])?["laravel/framework"] as? String
            metadata.hasHorizon = allDeps.contains("laravel/horizon")
            metadata.hasReverb = allDeps.contains("laravel/reverb")
            metadata.hasSail = allDeps.contains("laravel/sail")
        }

        let env = readEnvFile(at: path)
        metadata.appURL = env["APP_URL"]
        metadata.appEnv = env["APP_ENV"]
        metadata.appDebug = env["APP_DEBUG"]
        if metadata.appName == nil {
            metadata.appName = env["APP_NAME"]
        }
        metadata.safeEnvironment = redacted(env)

        return metadata
    }

    static func readComposerJSON(at path: String) -> [String: Any]? {
        let url = URL(fileURLWithPath: path).appendingPathComponent("composer.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func readEnvFile(at path: String) -> [String: String] {
        let url = URL(fileURLWithPath: path).appendingPathComponent(".env")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }

        var result: [String: String] = [:]
        for rawLine in contents.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eqIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eqIndex]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }

    private static func redacted(_ env: [String: String]) -> [String: String] {
        let sensitiveMarkers = ["PASSWORD", "SECRET", "KEY", "TOKEN"]
        return env.filter { key, _ in
            !sensitiveMarkers.contains { key.uppercased().contains($0) }
        }
    }
}
