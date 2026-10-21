import Foundation
import PhpSwitcherCore

/// `require.php` from a project's composer.json, checked against the linked Homebrew PHP.
nonisolated enum ProjectPhpRequirement {
    /// Native projects only: Sail / Compose run PHP in a container.
    static func constraint(for project: Project) -> PhpConstraint? {
        guard project.environment == .native, !project.hasDockerCompose else { return nil }
        return constraint(atPath: project.path)
    }

    static func constraint(atPath path: String) -> PhpConstraint? {
        let url = URL(fileURLWithPath: path).appendingPathComponent("composer.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return constraint(fromComposerJSON: data)
    }

    static func constraint(fromComposerJSON data: Data) -> PhpConstraint? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let require = json["require"] as? [String: Any],
              let php = require["php"] as? String else { return nil }
        return PhpConstraint(php)
    }
}

/// What the dashboard shows when the active PHP doesn't fit the project.
struct ProjectPhpMismatch: Equatable {
    let constraint: String
    let active: String
    /// Newest installed version that fits, if any.
    let suggestion: PhpInstallation?
}

extension PhpManager {
    /// nil when the project fits the active PHP (or there's nothing to check).
    func mismatch(for project: Project) -> ProjectPhpMismatch? {
        guard let constraint = ProjectPhpRequirement.constraint(for: project),
              let active = snapshot.active,
              !constraint.satisfies(active.version) else { return nil }
        return ProjectPhpMismatch(constraint: constraint.description,
                                  active: active.version.short,
                                  suggestion: constraint.bestMatch(in: snapshot.installed))
    }
}
