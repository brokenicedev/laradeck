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

    /// Midnight / Daylight follow the OS when syncing; otherwise the picked theme.
    var theme: AppTheme {
        if syncWithSystem { return systemIsDark ? .midnight : .daylight }
        return AppTheme.named(themeName)
    }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let theme = "appTheme"
        static let sync = "appThemeSyncWithSystem"
        static let animated = "appThemeAnimatedBackground"
    }

    private init() {
        themeName = defaults.string(forKey: Keys.theme) ?? AppTheme.midnight.name
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
    /// for mono themes. Controls keep the system accent (gray bordered buttons, blue prominent ones).
    func appThemed() -> some View {
        modifier(AppThemeModifier())
    }
}

extension View {
    /// Title bar / toolbar in the theme's header color instead of the system gray.
    /// Applied per column too, since split views resolve the toolbar background per column.
    func themedToolbar() -> some View {
        let theme = ThemeStore.shared.theme
        return toolbarBackground(theme.header, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
    }
}

private struct AppThemeModifier: ViewModifier {
    func body(content: Content) -> some View {
        let theme = ThemeStore.shared.theme
        content
            .preferredColorScheme(theme.colorScheme)
            .fontDesign(theme.monospace ? .monospaced : .default)
            .themedToolbar()
    }
}
