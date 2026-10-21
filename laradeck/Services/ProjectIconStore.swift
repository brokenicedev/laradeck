import Foundation
import UniformTypeIdentifiers

/// Stores user-selected project logos under Application Support (copied from the user's disk).
nonisolated enum ProjectIconStore {
    private static let subdirectory = "ProjectIcons"

    private static var iconsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Laradeck/\(subdirectory)", isDirectory: true)
    }

    static let supportedExtensions = ["png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "heic", "tif", "tiff"]

    static var openPanelTypes: [UTType] {
        [.png, .jpeg, .gif, .webP, .svg, .ico, .heic, .tiff, .image]
    }

    /// Copies `sourceURL` into app storage and returns the persisted absolute path.
    static func importIcon(from sourceURL: URL, projectId: UUID) throws -> String {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: iconsDirectory, withIntermediateDirectories: true)

        let ext = sourceURL.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw ImportError.unsupportedFormat
        }

        removeIcon(for: projectId)

        let destination = iconsDirectory.appendingPathComponent("\(projectId.uuidString).\(ext)")
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination.path
    }

    static func removeIcon(for projectId: UUID) {
        guard let directoryContents = try? FileManager.default.contentsOfDirectory(
            at: iconsDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for fileURL in directoryContents where fileURL.deletingPathExtension().lastPathComponent == projectId.uuidString {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    enum ImportError: LocalizedError {
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                return "Unsupported image format. Use PNG, JPEG, GIF, WebP, SVG, or ICO."
            }
        }
    }
}
