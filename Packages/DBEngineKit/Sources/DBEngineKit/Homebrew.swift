import Foundation

public enum HomebrewError: LocalizedError {
    case notInstalled
    case installFailed(String, output: String)
    case incompatible(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: "Homebrew is not installed. Get it from https://brew.sh"
        case let .installFailed(f, out): "brew install \(f) failed:\n\(out)"
        case let .incompatible(msg): msg
        }
    }
}

/// Engine binaries from Homebrew. Services point at the stable `opt/<formula>`
/// symlink, so `brew upgrade` (same formula) keeps them working.
public enum Homebrew {
    public static var prefix: URL? {
        ["/opt/homebrew", "/usr/local"].map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("bin/brew").path) }
    }

    public static var brew: URL? { prefix?.appendingPathComponent("bin/brew") }

    /// Formulae offered for each engine, newest first.
    public static func formulae(for kind: EngineKind) -> [String] {
        switch kind {
        case .postgresql: ["postgresql@18", "postgresql@17", "postgresql@16", "postgresql@15", "postgresql@14"]
        case .mysql: ["mysql", "mysql@8.4", "mysql@8.0"]
        case .redis: ["redis"]
        }
    }

    /// Formula matching an existing service's major version (used when switching a service to Homebrew).
    public static func formula(for kind: EngineKind, version: String) -> String {
        let major = version.split(separator: ".").first.map(String.init) ?? version
        switch kind {
        case .postgresql: return "postgresql@\(major)"
        case .mysql:
            let mm = version.split(separator: ".").prefix(2).joined(separator: ".")
            return ["8.0", "8.4"].contains(mm) ? "mysql@\(mm)" : "mysql"
        case .redis: return "redis"
        }
    }

    /// Formula base name: versioned formulae are `<base>@<version>`.
    static func baseName(for kind: EngineKind) -> String {
        switch kind {
        case .postgresql: "postgresql"
        case .mysql: "mysql"
        case .redis: "redis"
        }
    }

    /// Installed Homebrew formulae that provide this engine's server binary,
    /// including versioned ones not in `formulae(for:)` (e.g. `redis@8.10`). Newest first.
    public static func installed(_ kind: EngineKind) -> [InstalledBinaries] {
        guard let prefix else { return [] }
        let opt = prefix.appendingPathComponent("opt")
        let base = baseName(for: kind)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: opt.path)) ?? []
        let candidates = Set(names.filter { $0 == base || $0.hasPrefix(base + "@") })
        let found: [InstalledBinaries] = candidates.compactMap { formula in
            let dir = opt.appendingPathComponent(formula)
            guard BinaryLocator.isValid(dir, kind: kind) else { return nil }
            // opt/postgresql@17 -> ../Cellar/postgresql@17/17.6 : the last component is the version.
            let version = dir.resolvingSymlinksInPath().lastPathComponent
            return InstalledBinaries(kind: kind, version: version, url: dir, formula: formula)
        }
        return found.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    public static func installedBinaries(formula: String, kind: EngineKind) -> InstalledBinaries? {
        installed(kind).first { $0.formula == formula }
    }

    /// Runs `brew install <formula>`, reporting each output line.
    /// Cancelling the calling Task terminates brew.
    public static func install(_ formula: String, output: (@Sendable (String) -> Void)? = nil) async throws {
        guard let brew else { throw HomebrewError.notInstalled }
        let p = Process()
        p.executableURL = brew
        p.arguments = ["install", "--formula", formula]
        var env = ProcessInfo.processInfo.environment
        env["NONINTERACTIVE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        let collected = LineCollector(output)
        pipe.fileHandleForReading.readabilityHandler = { h in collected.append(h.availableData) }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                // Set before run() so a fast exit can't be missed.
                p.terminationHandler = { _ in c.resume() }
                do { try p.run() } catch {
                    p.terminationHandler = nil
                    c.resume()
                }
            }
        } onCancel: {
            if p.isRunning { p.terminate() }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        guard p.processIdentifier != 0 else { throw HomebrewError.installFailed(formula, output: "could not launch brew") }
        collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
        try Task.checkCancellation()
        if p.terminationStatus != 0 {
            throw HomebrewError.installFailed(formula, output: collected.tail(20))
        }
    }
}

/// Thread-safe buffer that splits process output into lines.
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private var lines: [String] = []
    private let onLine: (@Sendable (String) -> Void)?

    init(_ onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        pending += String(decoding: data, as: UTF8.self)
        var parts = pending.components(separatedBy: "\n")
        pending = parts.removeLast()
        lines += parts
        lock.unlock()
        for line in parts where !line.isEmpty { onLine?(line) }
    }

    func tail(_ n: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        return (lines + [pending]).suffix(n).joined(separator: "\n")
    }
}
