import Foundation

/// Locates a Laravel project's own favicon under `public/`, so projects can be told apart at a
/// glance in the sidebar/dashboard the way browser tabs are.
nonisolated enum FaviconDetector {
    private static let candidateFilenames = [
        "favicon.svg",
        "favicon.png",
        "favicon.ico",
        "apple-touch-icon.png",
        "apple-touch-icon-precomposed.png",
        "favicon-32x32.png",
        "favicon-16x16.png",
    ]

    static func faviconPath(at projectPath: String) -> String? {
        let publicDir = (projectPath as NSString).appendingPathComponent("public")
        let fm = FileManager.default
        for filename in candidateFilenames {
            let candidate = (publicDir as NSString).appendingPathComponent(filename)
            if fm.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
