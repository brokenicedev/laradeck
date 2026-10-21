import Foundation

#if SPARKLE
import Sparkle

/// Thin wrapper around Sparkle 2 — only linked into direct (non–App Store) builds.
@MainActor
final class SparkleUpdaterController {
    static let shared = SparkleUpdaterController()

    private let updaterController: SPUStandardUpdaterController

    private init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
#else
/// Stub when Sparkle is not compiled in (App Store builds).
@MainActor
final class SparkleUpdaterController {
    static let shared = SparkleUpdaterController()
    var automaticallyChecksForUpdates = false
    func checkForUpdates() {}
}
#endif
