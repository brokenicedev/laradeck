import Foundation
import Observation

nonisolated enum PHPVersionStatus: Equatable {
    case unknown
    case installed(version: String)
    case notInstalled

    var helpText: String {
        switch self {
        case .unknown:
            return "Checking for the default PHP CLI in PATH…"
        case .installed(let version):
            return "PHP \(version) — default CLI used for native Laravel projects"
        case .notInstalled:
            return "PHP not found in PATH — install PHP or set a path override in Settings"
        }
    }
}

/// Detects the default `php` CLI on the host (not Sail containers).
@MainActor
@Observable
final class PHPVersionMonitor {
    private let runtimeResolver = RuntimeResolver.shared

    private(set) var status: PHPVersionStatus = .unknown

    func refresh() async {
        guard let phpPath = await runtimeResolver.resolvePath(for: "php") else {
            status = .notInstalled
            return
        }

        let output = await runVersion(executable: phpPath)
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
            process.arguments = ["-r", "echo PHP_VERSION;"]
            process.environment = environment

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = Pipe()

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

        let pattern = #"^(\d+\.\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let range = Range(match.range(at: 1), in: trimmed) else {
            return nil
        }
        return String(trimmed[range])
    }
}
