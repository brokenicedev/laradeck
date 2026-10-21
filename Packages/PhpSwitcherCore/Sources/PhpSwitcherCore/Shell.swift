import Foundation

public struct ShellResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }
}

public enum ShellError: Error, LocalizedError {
    case launchFailed(String)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let cmd): return "Could not launch: \(cmd)"
        case .timedOut(let cmd): return "Timed out: \(cmd)"
        }
    }
}

/// Abstraction over running shell commands, so the switcher can be tested
/// (or dry-run) without touching Homebrew.
public protocol Shell: Sendable {
    func run(_ command: String) async throws -> ShellResult
    /// Same as `run`, with a custom timeout (installs can take longer than 5 minutes).
    func run(_ command: String, timeout: TimeInterval) async throws -> ShellResult
}

extension Shell {
    public func run(_ command: String, timeout: TimeInterval) async throws -> ShellResult {
        try await run(command)
    }
}

/// Wraps a string in single quotes for /bin/sh.
public func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Brew settings PHP Monitor exports before install/remove commands
/// (`export HOMEBREW_NO_INSTALL_UPGRADE=true; export HOMEBREW_NO_INSTALL_CLEANUP=true; ...`).
public let brewInstallEnvironment =
    "export HOMEBREW_NO_INSTALL_UPGRADE=true; export HOMEBREW_NO_INSTALL_CLEANUP=true; " +
    "export HOMEBREW_DOWNLOAD_CONCURRENCY=auto; export HOMEBREW_NO_ASK=true; "

/// Runs commands through `/bin/sh -c` with a controlled PATH.
///
/// PHP Monitor does the same: it never relies on the user's login shell and
/// instead prefixes commands with `export PATH=...` that includes the Homebrew
/// bin directory (see the `export PATH=/usr/bin:/bin:/usr/sbin:/sbin:` string
/// in its binary). It also kills commands that run too long (5 minutes).
public struct SystemShell: Shell {
    public let homebrewPrefix: String
    public let timeout: TimeInterval

    public init(homebrewPrefix: String, timeout: TimeInterval = 300) {
        self.homebrewPrefix = homebrewPrefix
        self.timeout = timeout
    }

    public func run(_ command: String) async throws -> ShellResult {
        try await run(command, timeout: timeout)
    }

    public func run(_ command: String, timeout: TimeInterval) async throws -> ShellResult {
        let prefix = homebrewPrefix
        let home = NSHomeDirectory()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", command]

                var env = ProcessInfo.processInfo.environment
                // Includes Composer's global bin, like PHP Monitor's
                // `export PATH=$HOME/bin:~/.composer/vendor/bin:$PATH`.
                env["PATH"] = "\(home)/.composer/vendor/bin:\(prefix)/bin:\(prefix)/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
                // Same intent as PHP Monitor's HOMEBREW_NO_* exports: keep brew fast and quiet.
                env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
                env["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
                env["HOMEBREW_NO_ENV_HINTS"] = "1"
                process.environment = env

                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ShellError.launchFailed(command))
                    return
                }

                var timedOut = false
                let timer = DispatchWorkItem {
                    if process.isRunning {
                        timedOut = true
                        process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

                // Read stderr on another thread so neither pipe can fill up and block.
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                timer.cancel()

                if timedOut {
                    continuation.resume(throwing: ShellError.timedOut(command))
                    return
                }
                continuation.resume(returning: ShellResult(
                    exitCode: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    }
}
