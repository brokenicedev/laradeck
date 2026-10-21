import Foundation

enum LaradeckProjectImportResult {
    case imported(Project)
    case alreadyAdded
    case noProfile
    case failed(String)
}

/// Adds a project from `.laradeck` when present, otherwise reports `.noProfile` so the UI can open the wizard.
@MainActor
enum LaradeckProjectImporter {
    static func tryImport(at path: String, into appState: AppState) -> LaradeckProjectImportResult {
        if appState.projects.contains(where: { $0.path == path }) {
            return .alreadyAdded
        }

        do {
            guard let profile = try LaradeckProfileStore.load(from: path) else {
                return .noProfile
            }
            let project = profile.toProject(path: path)
            appState.addProject(project)
            return .imported(project)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
