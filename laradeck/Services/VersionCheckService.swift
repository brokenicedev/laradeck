import Foundation
import Observation

/// Fetches `version.json` and exposes whether a newer release is available.
@MainActor
@Observable
final class VersionCheckService {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(AppVersionInfo)
        case failed(String)
    }

    private(set) var status: Status = .idle
    /// When non-nil, the sidebar/dashboard banner should show this update.
    private(set) var bannerUpdate: AppVersionInfo?

    private let feedURL: URL
    private let session: URLSession
    private let defaults: UserDefaults
    private let localVersion: () -> LocalAppVersion

    private static let lastCheckKey = "versionCheck.lastCheckAt"
    private static let skippedBuildKey = "versionCheck.skippedBuild"
    private static let dismissedBuildKey = "versionCheck.dismissedBuild"
    private static let checkInterval: TimeInterval = 60 * 60 * 24

    init(
        feedURL: URL = AppLinks.versionFeed,
        session: URLSession = .shared,
        defaults: UserDefaults = .standard,
        localVersion: @escaping () -> LocalAppVersion = { .current }
    ) {
        self.feedURL = feedURL
        self.session = session
        self.defaults = defaults
        self.localVersion = localVersion
    }

    /// Background check on launch — at most once per 24 hours unless `force`.
    func checkForUpdatesIfNeeded(force: Bool = false) async {
        if !force, let last = defaults.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < Self.checkInterval,
           bannerUpdate != nil || status == .upToDate {
            return
        }
        await checkForUpdates(userInitiated: false)
    }

    /// Manual check from Settings / menu — always hits the network.
    func checkForUpdates(userInitiated: Bool) async {
        status = .checking
        defer { defaults.set(Date(), forKey: Self.lastCheckKey) }

        do {
            let remote = try await fetchFeed()
            let local = localVersion()
            if AppVersionComparison.isRemoteNewer(remote, than: local) {
                status = .updateAvailable(remote)
                let skipped = defaults.integer(forKey: Self.skippedBuildKey)
                let dismissed = defaults.integer(forKey: Self.dismissedBuildKey)
                if remote.build != skipped, remote.build != dismissed {
                    bannerUpdate = remote
                } else if userInitiated {
                    bannerUpdate = remote
                }
            } else {
                status = .upToDate
                bannerUpdate = nil
            }
        } catch {
            status = .failed(error.localizedDescription)
            if userInitiated {
                bannerUpdate = nil
            }
        }
    }

    func dismissBanner() {
        if case .updateAvailable(let info) = status {
            defaults.set(info.build, forKey: Self.dismissedBuildKey)
        } else if let bannerUpdate {
            defaults.set(bannerUpdate.build, forKey: Self.dismissedBuildKey)
        }
        bannerUpdate = nil
    }

    func skipThisVersion() {
        guard case .updateAvailable(let info) = status else {
            if let bannerUpdate {
                defaults.set(bannerUpdate.build, forKey: Self.skippedBuildKey)
            }
            bannerUpdate = nil
            return
        }
        defaults.set(info.build, forKey: Self.skippedBuildKey)
        bannerUpdate = nil
    }

    func openUpdate() {
        let info: AppVersionInfo?
        if case .updateAvailable(let remote) = status {
            info = remote
        } else {
            info = bannerUpdate
        }
        guard let info else { return }

        switch AppDistributionChannel.current {
        case .appStore:
            if let masURL = info.masURL {
                AppLinks.open(masURL)
            } else if let fallback = AppLinks.macAppStorePage {
                AppLinks.open(fallback)
            }
        case .direct:
#if SPARKLE
            SparkleUpdaterController.shared.checkForUpdates()
#else
            if let directURL = info.directURL {
                AppLinks.open(directURL)
            } else {
                AppLinks.open(AppLinks.githubReleases)
            }
#endif
        }
    }

    private func fetchFeed() async throws -> AppVersionInfo {
        var request = URLRequest(url: feedURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(AppVersionInfo.self, from: data)
    }
}
