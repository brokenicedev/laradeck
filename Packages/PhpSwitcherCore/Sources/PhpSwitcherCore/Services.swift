import Foundation

public enum ServiceAction: String, Sendable {
    case start, stop, restart
}

/// One row of `brew services list --json`.
public struct ServiceInfo: Sendable, Hashable, Decodable {
    public let name: String
    public let status: String?
    public let user: String?

    public init(name: String, status: String?, user: String? = nil) {
        self.name = name
        self.status = status
        self.user = user
    }

    public var isRunning: Bool { status == "started" }
    public var hasError: Bool { status == "error" }
}

/// Homebrew services (PHP-FPM, nginx, dnsmasq).
///
/// With Valet these run as root (`/Library/LaunchDaemons/homebrew.mxcl.*.plist`),
/// so they must be managed with `sudo brew services`. PHP Monitor relies on the
/// passwordless sudoers entries that `valet trust` creates
/// (`/private/etc/sudoers.d/brew`, `/private/etc/sudoers.d/valet`); we use
/// `sudo -n` so a missing entry fails instead of hanging on a password prompt.
public struct Services: Sendable {
    public let homebrew: Homebrew
    public let useSudo: Bool

    public init(homebrew: Homebrew, useSudo: Bool) {
        self.homebrew = homebrew
        self.useSudo = useSudo
    }

    private var brewCommand: String {
        useSudo ? "sudo -n \(homebrew.brew)" : homebrew.brew
    }

    public func list() async -> [ServiceInfo] {
        guard let result = try? await homebrew.shell.run("\(brewCommand) services list --json"),
              result.succeeded else { return [] }
        return Self.parse(result.stdout)
    }

    public static func parse(_ json: String) -> [ServiceInfo] {
        guard let data = json.data(using: .utf8),
              let entries = try? JSONDecoder().decode([ServiceInfo].self, from: data) else { return [] }
        return entries
    }

    /// PHP formulae currently running as services.
    public func runningPhpServices() async -> Set<String> {
        Set(await list().filter { PhpInstallation.isPhpFormulaName($0.name) && $0.isRunning }.map(\.name))
    }

    @discardableResult
    public func perform(_ action: ServiceAction, _ name: String) async throws -> ShellResult {
        try await homebrew.shell.run("\(brewCommand) services \(action.rawValue) \(shellQuote(name))")
    }
}
