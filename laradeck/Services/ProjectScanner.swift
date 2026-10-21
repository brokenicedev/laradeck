import Foundation

nonisolated struct DiscoveredProject: Identifiable, Hashable {
    var id: String { path }
    let path: String
    var alreadyAdded: Bool

    var name: String {
        (path as NSString).lastPathComponent
    }
}

nonisolated enum ProjectScanner {
    /// Directories that can never meaningfully contain a *separate* Laravel project and are
    /// expensive or noisy to descend into (spec §7).
    private static let ignoredDirectoryNames: Set<String> = [
        "vendor", "node_modules", ".git", "storage", "bootstrap",
        ".build", "DerivedData", ".next", ".output", "dist", "build"
    ]

    static func scan(rootPaths: [String], existingPaths: Set<String> = [], maxDepth: Int = 6) async -> [DiscoveredProject] {
        var foundPaths: [String] = []
        let fm = FileManager.default

        for root in rootPaths {
            let expanded = (root as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else { continue }
            walk(expanded, depth: 0, maxDepth: maxDepth, fm: fm, results: &foundPaths)
        }

        return foundPaths.map { path in
            DiscoveredProject(path: path, alreadyAdded: existingPaths.contains(path))
        }
    }

    private static func walk(_ path: String, depth: Int, maxDepth: Int, fm: FileManager, results: inout [String]) {
        if LaravelDetector.isLaravelProject(at: path) {
            results.append(path)
            return
        }
        guard depth < maxDepth else { return }
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return }

        for entry in entries {
            if entry.hasPrefix(".") || ignoredDirectoryNames.contains(entry) { continue }
            let fullPath = (path as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else { continue }
            walk(fullPath, depth: depth + 1, maxDepth: maxDepth, fm: fm, results: &results)
        }
    }
}
