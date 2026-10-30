import AppKit
import Observation
import SwiftUI

/// Selected app theme, persisted in UserDefaults. Views read `ThemeStore.shared.theme`
/// (directly or via `LaradeckTheme`), so Observation re-renders them when it changes.
@MainActor
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    var themeName: String { didSet { defaults.set(themeName, forKey: Keys.theme) } }
    var syncWithSystem: Bool { didSet { defaults.set(syncWithSystem, forKey: Keys.sync) } }
    var animatedBackground: Bool { didSet { defaults.set(animatedBackground, forKey: Keys.animated) } }
    private(set) var systemIsDark: Bool

    /// Snowflake / Snowflake Light follow the OS when syncing; otherwise the picked theme.
    var theme: AppTheme {
        if syncWithSystem { return systemIsDark ? .snowflake : .snowflakeLight }
        return AppTheme.named(themeName)
    }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let theme = "appTheme"
        static let sync = "appThemeSyncWithSystem"
        static let animated = "appThemeAnimatedBackground"
    }

    private init() {
        themeName = defaults.string(forKey: Keys.theme) ?? AppTheme.snowflake.name
        syncWithSystem = defaults.object(forKey: Keys.sync) as? Bool ?? true
        animatedBackground = defaults.object(forKey: Keys.animated) as? Bool ?? true
        systemIsDark = Self.readSystemIsDark()

        // The app's own appearance is forced by the theme, so read the global OS setting instead.
        DistributedNotificationCenter.default().addObserver(
            forName: .init("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { _ in
            Task { @MainActor in ThemeStore.shared.systemIsDark = Self.readSystemIsDark() }
        }
    }

    func select(_ theme: AppTheme) {
        syncWithSystem = false
        themeName = theme.name
    }

    private nonisolated static func readSystemIsDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }
}

extension View {
    /// Applies the active theme to a scene's root: color scheme, title bar color, monospaced font
    /// for mono themes. Flat themes keep the system accent on controls; glass (Snowflake) themes
    /// tint controls with their accent, like Snowflake Desktop.
    func appThemed() -> some View {
        modifier(AppThemeModifier())
    }
}

extension View {
    /// Title bar / toolbar in the theme's header color instead of the system gray.
    /// Glass themes hide the toolbar background so the gradient shows through.
    /// Applied per column too, since split views resolve the toolbar background per column.
    @ViewBuilder
    func themedToolbar() -> some View {
        let theme = ThemeStore.shared.theme
        if theme.glass {
            // Like Snowflake Desktop: no toolbar material at all, so it never appears on hover/scroll.
            toolbarBackground(.hidden, for: .windowToolbar)
        } else {
            toolbarBackground(theme.header, for: .windowToolbar)
                .toolbarBackground(.visible, for: .windowToolbar)
        }
    }
}

private struct AppThemeModifier: ViewModifier {
    func body(content: Content) -> some View {
        let theme = ThemeStore.shared.theme
        content
            .preferredColorScheme(theme.colorScheme)
            .fontDesign(theme.monospace ? .monospaced : .default)
            .tint(theme.glass ? theme.accent : nil)
            .themedToolbar()
    }
}
