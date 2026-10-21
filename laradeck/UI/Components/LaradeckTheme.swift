import SwiftUI
import AppKit

/// Shared surfaces, all macOS semantic colors so light/dark mode and accessibility
/// settings (Increase Contrast, Reduce Transparency) are handled by the system.
enum LaradeckTheme {
    /// Content area behind sections — white in light mode, like Apple's document-style apps.
    static var pageBackground: Color { Color(nsColor: .textBackgroundColor) }

    /// Grouped section fill.
    static var cardBackground: Color { Color(nsColor: .controlBackgroundColor) }

    static var cardBorder: Color { Color(nsColor: .separatorColor) }

    static var buttonBorder: Color { Color(nsColor: .separatorColor) }

    static let cardCornerRadius: CGFloat = 10
    static let buttonCornerRadius: CGFloat = 8
}

extension View {
    /// White (or dark-elevated) card on the gray page background.
    func laradeckCard(cornerRadius: CGFloat = LaradeckTheme.cardCornerRadius) -> some View {
        background(LaradeckTheme.cardBackground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(LaradeckTheme.cardBorder, lineWidth: 1)
            }
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
