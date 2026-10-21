import Foundation

/// Resolves absolute paths for developer tools (php, composer, node, package managers, docker, git).
///
/// GUI apps on macOS don't inherit the PATH a user's login shell builds up via Homebrew, asdf,
/// mise, nvm, fnm, Volta or Herd (spec §51) — so beyond a few common install locations, this
/// falls back to asking a login shell directly.
nonisolated final class RuntimeResolver: @unchecked Sendable {
    static let shared = RuntimeResolver()

    static let knownTools = ["php", "composer", "node", "npm", "pnpm", "yarn", "bun", "docker", "git", "laravel"]

    private let commonSearchPaths = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/usr/bin",
        "/bin",
    ]

    private let lock = NSLock()
    private var cache: [String: String?] = [:]
    private var overrides: [String: String] = [:]
    private var loginEnvironmentCache: [String: String]?

    private init() {
        loadPersistedOverrides()
    }

    func overridePath(for tool: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return overrides[tool]
    }

    func allOverrides() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return overrides
    }

    private static let overridesKey = "runtimePathOverrides"

    /// Loads path overrides saved from Settings (called once at app launch).
    func loadPersistedOverrides() {
        lock.lock()
        defer { lock.unlock() }
        if let saved = UserDefaults.standard.dictionary(forKey: Self.overridesKey) as? [String: String] {
            overrides = saved
        }
    }

    /// Manual override from Settings > Commands takes priority over auto-detection.
    func setOverride(_ path: String?, for tool: String) {
        lock.lock()
        defer { lock.unlock() }
        if let path, !path.isEmpty {
            overrides[tool] = path
        } else {
            overrides.removeValue(forKey: tool)
        }
        cache.removeValue(forKey: tool)
        UserDefaults.standard.set(overrides, forKey: Self.overridesKey)
    }

    func resolvePath(for tool: String) async -> String? {
        lock.lock()
        if let override = overrides[tool] {
            lock.unlock()
            return override
        }
        if let cached = cache[tool] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var resolved: String?
        for dir in commonSearchPaths {
            let candidate = (dir as NSString).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                resolved = candidate
                break
            }
        }

        if resolved == nil {
            let toolName = tool
            resolved = await Task.detached {
                Self.resolveViaLoginShell(toolName)
            }.value
        }

        lock.lock()
        cache[tool] = resolved
        lock.unlock()
        return resolved
    }

    /// Path to `vendor/bin/sail` inside a given project, if present.
    func sailBinary(inProject projectPath: String) -> String? {
        let candidate = (projectPath as NSString).appendingPathComponent("vendor/bin/sail")
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    /// The full environment a login shell ends up with (PATH plus anything nvm/fnm/Volta/asdf/mise
    /// export on top of it) — cached after the first call.
    ///
    /// Resolving just the absolute path to a tool isn't enough: spawned tools frequently shell out
    /// to other binaries themselves (npm scripts invoking `node`, `node-gyp`, etc. via PATH), and
    /// without this those nested lookups only see the GUI app's minimal PATH and fail even though
    /// the same command works fine from Terminal.
    func loginShellEnvironment() async -> [String: String] {
        lock.lock()
        if let cached = loginEnvironmentCache {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = await Task.detached {
            Self.resolveLoginShellEnvironment()
        }.value

        lock.lock()
        loginEnvironmentCache = resolved
        lock.unlock()
        return resolved
    }

    private static func resolveLoginShellEnvironment() -> [String: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ilc", "env"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return [:]
        }
        process.waitUntilExit()

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [:] }

        var result: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let eqIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eqIndex])
            let value = String(line[line.index(after: eqIndex)...])
            result[key] = value
        }
        return result
    }

    private static func resolveViaLoginShell(_ tool: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ilc", "which \(tool)"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        let firstLine = output
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces)

        guard let path = firstLine, path.hasPrefix("/") else { return nil }
        return path
    }
}
