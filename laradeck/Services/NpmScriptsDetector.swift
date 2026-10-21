import Foundation

/// Reads the `scripts` block of a project's package.json, so Laradeck can propose/quick-add
/// exactly what the project actually defines (e.g. a custom "watch" script) instead of only
/// ever guessing "dev".
nonisolated enum NpmScriptsDetector {
    static func scripts(at projectPath: String) -> [String: String] {
        let url = URL(fileURLWithPath: projectPath).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = object["scripts"] as? [String: String] else {
            return [:]
        }
        return scripts
    }
}
