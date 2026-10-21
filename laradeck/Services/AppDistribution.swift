import Foundation

/// How this binary was built for distribution — drives update CTAs.
enum AppDistributionChannel: Equatable {
    /// Developer ID / direct download (Sparkle when enabled).
    case direct
    /// Mac App Store — updates only via the store.
    case appStore

    static var current: AppDistributionChannel {
        #if APP_STORE
        return .appStore
        #else
        return .direct
        #endif
    }

    var usesSparkle: Bool {
        #if SPARKLE
        return self == .direct
        #else
        return false
        #endif
    }
}
