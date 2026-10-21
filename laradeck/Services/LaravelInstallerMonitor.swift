import Foundation
import Observation

nonisolated enum LaravelInstallerStatus: Equatable {
    case unknown
    case installed(version: String)
    case notInstalled

    var label: String {
        switch self {
        case .unknown: return "Checking…"
        case .installed(let version): return "Installer \(version)"
        case .notInstalled: return "Installer not found"
        }
    }

    var helpText: String {
        switch self {
        case .unknown: return "Checking for the global Laravel installer (`laravel new`)…"
        case .installed(let version): return "Laravel Installer \(version) — available for `laravel new`"
        case .notInstalled: return "Laravel Installer not found in PATH — install with Composer global require"
        }
    }
}

/// Detects the global `laravel` CLI used by `laravel new`.
@MainActor
@Observable
final class LaravelInstallerMonitor {
    private let runtimeResolver = RuntimeResolver.shared

    private(set) var status: LaravelInstallerStatus = .unknown

    func refresh() async {
        guard let laravelPath = await runtimeResolver.resolvePath(for: "laravel") else {
            status = .notInstalled
            return
        }

        let output = await runVersion(executable: laravelPath)
        if let version = Self.parseVersion(from: output) {
            status = .installed(version: version)
        } else {
            status = .notInstalled
        }
    }

    private func runVersion(executable: String) async -> String {
        var environment = await runtimeResolver.loginShellEnvironment()
        if environment.isEmpty {
            environment = ProcessInfo.processInfo.environment
        }

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["--version"]
            process.environment = environment

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            process.terminationHandler = { _ in
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: text)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: "")
            }
        }
    }

    private static func parseVersion(from output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let pattern = #"Installer\s+(\d+\.\d+\.\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let range = Range(match.range(at: 1), in: trimmed) else {
            return nil
        }
        return String(trimmed[range])
    }
}
