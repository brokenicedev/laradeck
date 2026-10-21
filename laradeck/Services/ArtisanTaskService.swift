import Foundation

/// Runs ephemeral artisan commands without adding them to the project's process list.
nonisolated enum ArtisanTaskService {
    static func run(_ task: ArtisanTask, project: Project) async -> ArtisanTaskResult {
        let shellInvocation = LaravelInsightsService.artisanShellInvocation(
            arguments: task.artisanArguments,
            project: project
        )
        let escapedPath = project.path.replacingOccurrences(of: "'", with: "'\\''")
        let shellCommand = "cd '\(escapedPath)' && \(shellInvocation)"

        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-ilc", shellCommand]

            let errorPipe = Pipe()
            process.standardOutput = Pipe()
            process.standardError = errorPipe

            do {
                try process.run()
            } catch {
                return ArtisanTaskResult(task: task, exitCode: -1, stderrSnippet: error.localizedDescription)
            }
            process.waitUntilExit()

            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = stderr.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }

            return ArtisanTaskResult(
                task: task,
                exitCode: process.terminationStatus,
                stderrSnippet: snippet
            )
        }.value
    }
}
