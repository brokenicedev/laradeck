import Foundation

public enum SwitchError: Error, LocalizedError {
    case binaryMissing(String)
    case commandFailed(command: String, output: String)
    case validationFailed(expected: VersionNumber, actual: VersionNumber?)

    public var errorDescription: String? {
        switch self {
        case .binaryMissing(let formula):
            return "\(formula) has no php binary. This PHP version is unavailable."
        case .commandFailed(let command, let output):
            return "Command failed: \(command)\n\(output)"
        case .validationFailed(let expected, let actual):
            return "Expected PHP \(expected.short) after switching, but found \(actual?.description ?? "no PHP")."
        }
    }
}

/// One step of a switch. Kept as data so it can be shown, tested or dry-run.
public enum SwitchStep: Sendable, Equatable, CustomStringConvertible {
    case unlink(String)
    case link(String)
    case service(ServiceAction, String)
    case prepareValetFpm(String)     // X.Y
    case linkValetSocket(String)     // X.Y

    public var description: String {
        switch self {
        case .unlink(let f): return "brew unlink \(f)"
        case .link(let f): return "brew link \(f) --overwrite --force"
        case .service(let action, let name): return "brew services \(action.rawValue) \(name)"
        case .prepareValetFpm(let v): return "check Valet FPM config for PHP \(v)"
        case .linkValetSocket(let v): return "ln -sF valet\(v.replacingOccurrences(of: ".", with: "")).sock valet.sock"
        }
    }
}

public struct SwitchOutcome: Sendable {
    public let active: ActivePhp
    /// Steps that failed without stopping the switch, and Valet fixes applied.
    public let notes: [String]
}

/// Switches the globally linked PHP version, following PHP Monitor's
/// `InternalSwitcher`:
///
/// 1. unlink every installed PHP formula and stop its service if it was running,
///    except versions used by isolated Valet sites
///    ("Unlinked and stopped services for …", "… is an isolated PHP version")
/// 2. `brew link <target> --overwrite --force`
/// 3. with Valet: check the FPM pool, (re)start the target service as root, point
///    `valet.sock` at the new version and restart nginx
///    ("Symlinked new socket version", "Restarting nginx, just to be sure!")
///    without Valet: start the target service if PHP was running as a service
/// 4. check that `<prefix>/bin/php` reports the requested version ("Validation passed.")
public struct PhpSwitcher: Sendable {
    public let homebrew: Homebrew
    public let services: Services
    public let valet: Valet?

    public init(homebrew: Homebrew, services: Services, valet: Valet?) {
        self.homebrew = homebrew
        self.services = services
        self.valet = valet
    }

    /// Pure function: the steps needed to make `target` the active PHP.
    public static func plan(
        target: PhpInstallation,
        installed: [PhpInstallation],
        runningServices: Set<String>,
        usesValet: Bool,
        isolatedVersions: Set<String> = []
    ) -> [SwitchStep] {
        var steps: [SwitchStep] = []
        for item in installed {
            steps.append(.unlink(item.formula))
            let isolated = isolatedVersions.contains(item.version.short)
            if runningServices.contains(item.formula) && !isolated && item.formula != target.formula {
                steps.append(.service(.stop, item.formula))
            }
        }
        steps.append(.link(target.formula))

        if usesValet {
            steps.append(.prepareValetFpm(target.version.short))
            steps.append(.service(.restart, target.formula))
            steps.append(.linkValetSocket(target.version.short))
            steps.append(.service(.restart, "nginx"))
        } else if !runningServices.isEmpty {
            steps.append(.service(.restart, target.formula))
        }
        return steps
    }

    public func plan(target: PhpInstallation, installed: [PhpInstallation]) async -> [SwitchStep] {
        let running = await services.runningPhpServices()
        return Self.plan(
            target: target,
            installed: installed,
            runningServices: running,
            usesValet: valet != nil,
            isolatedVersions: valet?.isolatedVersions() ?? []
        )
    }

    @discardableResult
    public func switchTo(
        _ target: PhpInstallation,
        installed: [PhpInstallation],
        progress: @Sendable (SwitchStep) -> Void = { _ in }
    ) async throws -> SwitchOutcome {
        guard FileManager.default.isExecutableFile(atPath: "\(homebrew.prefix)/opt/\(target.formula)/bin/php") else {
            throw SwitchError.binaryMissing(target.formula)
        }

        var notes: [String] = []
        for step in await plan(target: target, installed: installed) {
            progress(step)
            switch step {
            case .unlink(let formula):
                try await homebrew.brew("unlink \(formula)")
            case .link(let formula):
                let result = try await homebrew.brew("link \(formula) --overwrite --force")
                if !result.succeeded {
                    throw SwitchError.commandFailed(command: step.description, output: result.stderr + result.stdout)
                }
            case .service(let action, let name):
                let result = try await services.perform(action, name)
                if !result.succeeded {
                    notes.append("\(step.description) failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            case .prepareValetFpm:
                notes += try valet?.ensureFpmConfiguration(for: target.version) ?? []
            case .linkValetSocket:
                try valet?.linkSocket(for: target.version)
            }
        }

        let active = await homebrew.activePhp()
        guard let active, active.version.sameMinor(as: target.version) else {
            throw SwitchError.validationFailed(expected: target.version, actual: active?.version)
        }
        return SwitchOutcome(active: active, notes: notes)
    }
}
