import Foundation

/// Remote version feed payload (`website/version.json` on laradeck.brokenice.it).
/// `direct_url` should point at a GitHub Release asset.
struct AppVersionInfo: Codable, Equatable, Sendable {
    let latest: String
    let build: Int
    let notes: String?
    let directURL: URL?
    let masURL: URL?
    let minOS: String?

    enum CodingKeys: String, CodingKey {
        case latest
        case build
        case notes
        case directURL = "direct_url"
        case masURL = "mas_url"
        case minOS = "min_os"
    }
}

/// Local marketing + build versions from the running bundle.
struct LocalAppVersion: Equatable, Sendable {
    let marketing: String
    let build: Int

    nonisolated static var current: LocalAppVersion {
        let info = Bundle.main.infoDictionary
        let marketing = (info?["CFBundleShortVersionString"] as? String) ?? "0"
        let buildString = (info?["CFBundleVersion"] as? String) ?? "0"
        let build = Int(buildString) ?? 0
        return LocalAppVersion(marketing: marketing, build: build)
    }
}

enum AppVersionComparison {
    /// True when the remote feed describes a newer release than the running app.
    /// Marketing version wins: a higher feed `build` never outranks an older `latest`.
    nonisolated static func isRemoteNewer(_ remote: AppVersionInfo, than local: LocalAppVersion) -> Bool {
        switch compareMarketingVersions(remote.latest, local.marketing) {
        case .orderedDescending:
            return true
        case .orderedAscending:
            return false
        case .orderedSame:
            return remote.build > local.build
        }
    }

    /// Loose semver-ish compare: splits on non-digits, compares numeric parts left-to-right.
    nonisolated static func compareMarketingVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = numericComponents(lhs)
        let right = numericComponents(rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b {
                return a > b ? .orderedDescending : .orderedAscending
            }
        }
        return .orderedSame
    }

    nonisolated private static func numericComponents(_ version: String) -> [Int] {
        version
            .split { !$0.isNumber }
            .compactMap { Int($0) }
    }
}
