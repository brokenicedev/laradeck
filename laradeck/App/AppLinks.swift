import Foundation
#if os(macOS)
import AppKit
#endif

/// External URLs used by Help, About and footer links — single source of truth.
nonisolated enum AppLinks {
    static let brokenice = URL(string: "https://brokenice.it")!
    static let laradeckSite = URL(string: "https://laradeck.brokenice.it")!
    static let contactEmail = URL(string: "mailto:hello@brokenice.it")!
    static let githubRepository = URL(string: "https://github.com/brokenicedev/laradeck")!
    static let githubIssues = URL(string: "https://github.com/brokenicedev/laradeck/issues")!
    static let githubReadme = URL(string: "https://github.com/brokenicedev/laradeck#readme")!
    static let githubReleases = URL(string: "https://github.com/brokenicedev/laradeck/releases")!

    /// Soft update feed — hosted on the Laradeck site (not GitHub).
    /// Source file: `website/version.json` → https://laradeck.brokenice.it/version.json
    static let versionFeed = URL(string: "https://laradeck.brokenice.it/version.json")!

    /// Sparkle appcast — same host as the soft feed.
    /// Source file: `website/appcast.xml` → https://laradeck.brokenice.it/appcast.xml
    /// Enclosure URLs point at GitHub Release zip assets.
    static let sparkleAppcast = URL(string: "https://laradeck.brokenice.it/appcast.xml")!

    /// Set once the Mac App Store listing exists (also mirrored in `version.json` → `mas_url`).
    static let macAppStorePage: URL? = nil

    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }
}
