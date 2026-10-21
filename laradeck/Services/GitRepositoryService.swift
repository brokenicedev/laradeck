import Foundation

/// Reads git metadata from a project folder for dashboard display.
nonisolated enum GitRepositoryService {
    /// Current branch name, or a short commit ref when HEAD is detached. Nil when not a git repo.
    static func currentBranch(at projectPath: String) async -> String? {
        guard LaradeckProfileStore.looksLikeGitRepo(at: projectPath) else { return nil }

        if let branch = await runGit(["-C", projectPath, "branch", "--show-current"]),
           !branch.isEmpty {
            return branch
        }

        return await runGit(["-C", projectPath, "rev-parse", "--short", "HEAD"])
    }

    private static func runGit(_ arguments: [String]) async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments

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
            let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value, !value.isEmpty else { return nil }
            return value
        }.value
    }
}
