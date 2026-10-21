import Foundation

nonisolated struct PackageManagerDetection: Equatable {
    let manager: PackageManager
    /// Lock file used for detection; nil when only `package.json` is present.
    let sourceFile: String?

    var isConfident: Bool { sourceFile != nil }

    var label: String {
        switch manager {
        case .none: return "None"
        default: return manager.executableName
        }
    }

    var detail: String {
        guard manager != .none else { return "No package.json" }
        let example = ([manager.executableName] + manager.runScriptArguments("dev")).joined(separator: " ")
        if let sourceFile {
            return "\(example) — detected from \(sourceFile)"
        }
        return "\(example) — choose the tool you use for frontend scripts"
    }
}

nonisolated enum PackageManagerDetector {
    static func detectDetailed(at path: String) -> PackageManagerDetection {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool {
            fm.fileExists(atPath: (path as NSString).appendingPathComponent(name))
        }

        if exists("pnpm-lock.yaml") { return PackageManagerDetection(manager: .pnpm, sourceFile: "pnpm-lock.yaml") }
        if exists("yarn.lock") { return PackageManagerDetection(manager: .yarn, sourceFile: "yarn.lock") }
        if exists("bun.lockb") { return PackageManagerDetection(manager: .bun, sourceFile: "bun.lockb") }
        if exists("bun.lock") { return PackageManagerDetection(manager: .bun, sourceFile: "bun.lock") }
        if exists("package-lock.json") { return PackageManagerDetection(manager: .npm, sourceFile: "package-lock.json") }
        if exists("package.json") { return PackageManagerDetection(manager: .npm, sourceFile: nil) }
        return PackageManagerDetection(manager: .none, sourceFile: nil)
    }

    static func detect(at path: String) -> PackageManager {
        detectDetailed(at: path).manager
    }
}
