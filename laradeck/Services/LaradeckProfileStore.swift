import Foundation

enum LaradeckProfileStoreError: LocalizedError {
    case unsupportedVersion(Int)
    case encodeFailed
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Unsupported .laradeck version \(version)."
        case .encodeFailed:
            return "Could not encode .laradeck."
        case .writeFailed(let message):
            return "Could not write .laradeck: \(message)"
        }
    }
}

/// Reads and writes the portable `.laradeck` team config in a project root.
nonisolated enum LaradeckProfileStore {
    static let fileName = ".laradeck"

    static func profileURL(at projectPath: String) -> URL {
        URL(fileURLWithPath: projectPath, isDirectory: true).appendingPathComponent(fileName)
    }

    static func exists(at projectPath: String) -> Bool {
        FileManager.default.fileExists(atPath: profileURL(at: projectPath).path)
    }

    /// Returns nil when the file is missing. Throws on corrupt / unsupported content.
    static func load(from projectPath: String) throws -> LaradeckProjectProfile? {
        let url = profileURL(at: projectPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let profile = try JSONDecoder().decode(LaradeckProjectProfile.self, from: data)
        guard profile.version >= 1, profile.version <= LaradeckProjectProfile.currentVersion else {
            throw LaradeckProfileStoreError.unsupportedVersion(profile.version)
        }
        return profile
    }

    static func save(_ profile: LaradeckProjectProfile, to projectPath: String) throws {
        var profile = profile
        profile.version = LaradeckProjectProfile.currentVersion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(profile) else {
            throw LaradeckProfileStoreError.encodeFailed
        }
        let url = profileURL(at: projectPath)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw LaradeckProfileStoreError.writeFailed(error.localizedDescription)
        }
    }

    static func write(from project: Project) throws {
        try save(.from(project: project), to: project.path)
    }

    /// True when the folder looks like a git working tree (`.git` present).
    static func looksLikeGitRepo(at projectPath: String) -> Bool {
        let git = URL(fileURLWithPath: projectPath, isDirectory: true).appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: git.path)
    }
}
