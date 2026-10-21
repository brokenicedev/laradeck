import Foundation

/// Per-user launchd agent control, the same mechanism DBngin uses:
/// a plist written into the service folder, then
///   launchctl bootstrap gui/<uid> <plist>      (start)
///   launchctl bootout   gui/<uid>/<label>      (stop)
/// launchd owns the process, so servers keep running after the app quits
/// and are restarted if they crash (KeepAlive.SuccessfulExit = false).
public enum Launchd {
    static let launchctl = "/bin/launchctl"

    public enum State: Equatable, Sendable {
        case notLoaded
        case running(pid: Int32)
        case loaded(String) // loaded but not running, e.g. "waiting" or "spawn scheduled"
    }

    static var domain: String { "gui/\(getuid())" }

    /// Builds the agent plist. Uses PropertyListSerialization instead of the
    /// string concatenation seen in DBngin, so paths with `&` or `<` are escaped.
    public static func plist(label: String, arguments: [String], workingDirectory: URL,
                             logFile: URL, environment: [String: String] = [:],
                             fileLimit: Int? = nil) throws -> Data {
        var dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "WorkingDirectory": workingDirectory.path,
            "StandardOutPath": logFile.path,
            "StandardErrorPath": logFile.path,
            "ProcessType": "Interactive",
        ]
        if !environment.isEmpty { dict["EnvironmentVariables"] = environment }
        if let fileLimit {
            dict["SoftResourceLimits"] = ["NumberOfFiles": fileLimit]
            dict["HardResourceLimits"] = ["NumberOfFiles": fileLimit]
        }
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    public static func bootstrap(plist: URL) throws {
        try Shell.run([launchctl, "bootstrap", domain, plist.path])
    }

    public static func bootout(label: String) throws {
        let r = try Shell.run([launchctl, "bootout", "\(domain)/\(label)"], check: false)
        // 3 = "No such process": already stopped, which is fine.
        if r.status != 0 && r.status != 3 && state(label: label) != .notLoaded {
            throw CommandError(command: [launchctl, "bootout", "\(domain)/\(label)"], result: r)
        }
        // bootout returns while slow servers (mysqld) are still shutting down; wait for a clean exit.
        let deadline = Date().addingTimeInterval(30)
        while state(label: label) != .notLoaded && Date() < deadline {
            usleep(200_000)
        }
    }

    public static func state(label: String) -> State {
        guard let r = try? Shell.run([launchctl, "print", "\(domain)/\(label)"], check: false),
              r.status == 0 else { return .notLoaded }
        var state = "unknown"
        var pid: Int32?
        // Only top-level keys (one tab deep); nested sections reuse "state = …".
        for line in r.output.split(separator: "\n") where line.hasPrefix("\t") && !line.hasPrefix("\t\t") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("state = ") { state = String(t.dropFirst(8)) }
            if t.hasPrefix("pid = "), let p = Int32(t.dropFirst(6)) { pid = p }
        }
        if state == "running", let pid { return .running(pid: pid) }
        return .loaded(state)
    }
}
