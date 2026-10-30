import SwiftUI
import AppKit

/// Shared surfaces, read from the active `AppTheme` (Settings → Appearance).
/// Reading them inside a view body registers an Observation dependency, so views
/// re-render when the theme changes.
enum LaradeckTheme {
    static var current: AppTheme { ThemeStore.shared.theme }

    /// Content area behind sections.
    static var pageBackground: Color { current.pageBackground }

    /// Grouped section fill.
    static var cardBackground: Color { current.cardBackground }

    static var cardBorder: Color { current.border }

    static var buttonBorder: Color { current.border }

    static var accent: Color { current.accent }

    /// Glass (Snowflake) themes use rounder cards.
    static var cardCornerRadius: CGFloat { current.glass ? 14 : 10 }
    static let buttonCornerRadius: CGFloat = 8
}

extension View {
    /// White (or dark-elevated) card on the gray page background; frosted glass with a soft
    /// shadow on Snowflake themes.
    func laradeckCard(cornerRadius: CGFloat = LaradeckTheme.cardCornerRadius) -> some View {
        background(LaradeckTheme.cardBackground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(LaradeckTheme.cardBorder, lineWidth: 1)
            }
            .shadow(color: LaradeckTheme.current.cardShadow, radius: 12, y: 6)
    }
}

/// Native macOS bordered button (system bezel, focus ring, accessibility), with an optional
/// colored label for Start (green) / Stop (red) and a compact size for rows.
struct LaradeckOutlineButtonStyle: PrimitiveButtonStyle {
    var accent: Color? = nil
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(.bordered)
            .controlSize(compact ? .small : .regular)
            .foregroundStyle(accent ?? .primary)
    }
}

extension PrimitiveButtonStyle where Self == LaradeckOutlineButtonStyle {
    static var laradeckOutline: LaradeckOutlineButtonStyle { LaradeckOutlineButtonStyle() }

    static func laradeckOutline(accent: Color? = nil, compact: Bool = false) -> LaradeckOutlineButtonStyle {
        LaradeckOutlineButtonStyle(accent: accent, compact: compact)
    }
}

/// Outline-only icon control (play / stop / logs) — no filled chrome, matches process-row actions in the shot.
struct LaradeckIconButtonStyle: ButtonStyle {
    var accent: Color = .secondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(accent.opacity(configuration.isPressed ? 0.55 : 1))
            .frame(minWidth: 28, minHeight: 28)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == LaradeckIconButtonStyle {
    static func laradeckIcon(accent: Color = .secondary) -> LaradeckIconButtonStyle {
        LaradeckIconButtonStyle(accent: accent)
    }
}
