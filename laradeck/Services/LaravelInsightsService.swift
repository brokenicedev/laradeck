import Foundation

nonisolated enum LaravelInsightsService {
    static func loadInstant(project: Project) -> LaravelInsights {
        let env = LaravelDetector.readEnvFile(at: project.path)
        let metadata = LaravelDetector.detectMetadata(at: project.path)

        return LaravelInsights(
            appEnv: env["APP_ENV"],
            appDebug: env["APP_DEBUG"],
            sessionDriver: env["SESSION_DRIVER"],
            cacheDriver: env["CACHE_STORE"] ?? env["CACHE_DRIVER"],
            queueConnection: env["QUEUE_CONNECTION"],
            dbConnection: env["DB_CONNECTION"],
            storageLink: storageLinkStatus(at: project.path),
            hasHorizon: project.hasHorizon || metadata.hasHorizon,
            hasReverb: project.hasReverb || metadata.hasReverb,
            pendingMigrations: nil
        )
    }

    static func loadMigrationStatus(project: Project) async -> Int? {
        let output = await runArtisanCommand(["migrate:status", "--no-ansi"], project: project)
        guard let output else { return nil }
        return parsePendingMigrationCount(from: output)
    }

    static func storageLinkStatus(at projectPath: String) -> StorageLinkStatus {
        let fm = FileManager.default
        let projectRoot = URL(fileURLWithPath: projectPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let publicStoragePath = projectRoot.appendingPathComponent("public/storage").path
        let hostTargetPath = projectRoot
            .appendingPathComponent("storage/app/public", isDirectory: true)
            .path

        let linkDestination = try? fm.destinationOfSymbolicLink(atPath: publicStoragePath)
        let hasPublicStorageEntry = fm.fileExists(atPath: publicStoragePath) || linkDestination != nil

        guard hasPublicStorageEntry else {
            return .missing
        }

        guard let linkDestination else {
            return normalizedPathsEqual(publicStoragePath, hostTargetPath) ? .linked : .invalid
        }

        if linkPointsToPublicStorage(
            linkDestination,
            relativeToDirectory: projectRoot.appendingPathComponent("public").path,
            hostTargetPath: hostTargetPath
        ) {
            return .linked
        }

        return .invalid
    }

    private static func linkPointsToPublicStorage(
        _ destination: String,
        relativeToDirectory publicDirectory: String,
        hostTargetPath: String
    ) -> Bool {
        let resolvedTarget = resolveLinkDestination(destination, relativeTo: publicDirectory)
        if normalizedPathsEqual(resolvedTarget, hostTargetPath) {
            return true
        }

        // Sail/Docker: `storage:link` run in-container often points at /var/www/html/storage/app/public.
        let normalized = destination.replacingOccurrences(of: "\\", with: "/")
        guard normalized.contains("storage/app/public") else {
            return false
        }

        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: hostTargetPath, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func resolveLinkDestination(_ destination: String, relativeTo baseDirectory: String) -> String {
        let combined: String
        if destination.hasPrefix("/") {
            combined = destination
        } else {
            combined = (baseDirectory as NSString).appendingPathComponent(destination)
        }
        return URL(fileURLWithPath: combined).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func normalizedPathsEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = URL(fileURLWithPath: lhs).standardizedFileURL.resolvingSymlinksInPath().path
        let right = URL(fileURLWithPath: rhs).standardizedFileURL.resolvingSymlinksInPath().path
        return left == right
    }

    static func parsePendingMigrationCount(from output: String) -> Int? {
        var pending = 0
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("| No") {
                pending += 1
            }
        }
        return pending
    }

    private static func runArtisanCommand(_ arguments: [String], project: Project) async -> String? {
        let shellInvocation = artisanShellInvocation(arguments: arguments, project: project)
        let escapedPath = project.path.replacingOccurrences(of: "'", with: "'\\''")
        let shellCommand = "cd '\(escapedPath)' && \(shellInvocation)"

        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-ilc", shellCommand]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
            } catch {
                return nil
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        }.value
    }

    static func artisanShellInvocation(arguments: [String], project: Project) -> String {
        let quotedArgs = arguments.map { arg in
            "'\(arg.replacingOccurrences(of: "'", with: "'\\''"))'"
        }.joined(separator: " ")

        if project.environment == .sail {
            return "./vendor/bin/sail artisan \(quotedArgs)"
        }
        return "php artisan \(quotedArgs)"
    }
}
