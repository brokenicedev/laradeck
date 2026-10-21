import Foundation

/// Refreshes cached Laravel/PHP version strings shown in the dashboard.
nonisolated enum ProjectMetadataService {
    static func refresh(for project: Project) async -> (laravelVersion: String?, phpVersion: String?) {
        async let laravel = resolveLaravelVersion(at: project.path)
        async let php = resolvePHPVersion(project: project)
        return await (laravel, php)
    }

    private static func resolveLaravelVersion(at path: String) async -> String? {
        if let lockVersion = laravelVersionFromLock(at: path) {
            return lockVersion
        }
        let metadata = LaravelDetector.detectMetadata(at: path)
        if let constraint = metadata.laravelConstraint?.trimmingCharacters(in: .whitespaces), !constraint.isEmpty {
            return constraint
        }
        return nil
    }

    private static func laravelVersionFromLock(at path: String) -> String? {
        let url = URL(fileURLWithPath: path).appendingPathComponent("composer.lock")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let packages = json["packages"] as? [[String: Any]] else { return nil }

        for package in packages {
            guard package["name"] as? String == "laravel/framework",
                  let version = package["version"] as? String else { continue }
            return version.hasPrefix("v") ? String(version.dropFirst()) : version
        }
        return nil
    }

    private static func resolvePHPVersion(project: Project) async -> String? {
        let invocation: String
        if project.environment == .sail {
            invocation = "./vendor/bin/sail php -r 'echo PHP_VERSION;'"
        } else {
            invocation = "php -r 'echo PHP_VERSION;'"
        }
        let escapedPath = project.path.replacingOccurrences(of: "'", with: "'\\''")
        let shellCommand = "cd '\(escapedPath)' && \(invocation)"

        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-ilc", shellCommand]

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = Pipe()

            do {
                try process.run()
            } catch {
                return nil
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let version = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let version, !version.isEmpty else { return nil }
            return version
        }.value
    }
}
