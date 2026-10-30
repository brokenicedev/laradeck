import AppKit
import SwiftUI

/// App-wide color theme. Snowflake (dark + light, the default) plus the classic flat themes.
struct AppTheme: Equatable, Identifiable {
    var name: String
    var isDark: Bool
    var monospace = false
    /// Snowflake style: translucent window with drifting gradient blobs and frosted-glass cards.
    var glass = false
    /// Blob colors for glass themes (three stops, like Snowflake Desktop's presets).
    var blobs: [Color] = []

    var windowStart: Color
    var windowEnd: Color
    var header: Color
    var text: Color
    var secondaryText: Color
    var accent: Color
    var hover: Color
    var border: Color
    var codeBackground: Color
    var filename: Color
    var time: Color
    var separator: Color
    var snippetBackground: Color
    var snippetActiveLine: Color

    var dumpText: Color
    var dumpNumber: Color
    var dumpString: Color
    var dumpNote: Color
    var dumpReference: Color
    var dumpProperty: Color
    var dumpMeta: Color
    var dumpKey: Color
    var dumpIndex: Color
    var dumpEllipsis: Color

    /// Opaque terminal colors (SwiftTerm needs solid NSColors).
    var terminalBackground: NSColor
    var terminalForeground: NSColor

    var id: String { name }
    var colorScheme: ColorScheme { isDark ? .dark : .light }

    /// Cards and grouped sections: a faint lift over the window on dark themes, white on light ones.
    /// Glass themes use translucent frosted cards over the gradient.
    var cardBackground: Color {
        if glass { return isDark ? Color.white.opacity(0.07) : Color.white.opacity(0.6) }
        return isDark ? Color.white.opacity(0.045) : Color.white
    }

    /// Light themes have a white window; give the page a soft gray so white cards stand out.
    /// Glass themes leave it clear so the gradient background shows through.
    var pageBackground: Color {
        if glass { return .clear }
        return isDark ? windowStart : Color(white: 0.965)
    }

    /// Soft drop shadow under glass cards; flat themes have none.
    var cardShadow: Color { glass ? Color.black.opacity(isDark ? 0.35 : 0.10) : .clear }

    static let all: [AppTheme] = [.snowflake, .snowflakeLight, .midnight, .daylight, .hackerman, .artisan, .vishal]

    static func named(_ name: String) -> AppTheme {
        all.first { $0.name.lowercased() == name.lowercased() } ?? .snowflake
    }

    // Dump palettes are shared by all dark themes and by all light themes.
    private static func darkDump(_ t: inout AppTheme) {
        t.dumpText = Color(hex: "#a795db"); t.dumpNumber = Color(hex: "#2bd4bd"); t.dumpString = Color(hex: "#4ade80")
        t.dumpNote = Color(hex: "#828df8"); t.dumpReference = Color(hex: "#9ca3b0"); t.dumpProperty = Color(hex: "#e5e7eb")
        t.dumpMeta = Color(hex: "#bf83fc"); t.dumpKey = Color(hex: "#4ade80"); t.dumpIndex = Color(hex: "#61a6fa")
        t.dumpEllipsis = Color(hex: "#fb923c")
    }

    private static func lightDump(_ t: inout AppTheme) {
        t.dumpText = Color(hex: "#8e81b1"); t.dumpNumber = Color(hex: "#0d9488"); t.dumpString = Color(hex: "#16a34a")
        t.dumpNote = Color(hex: "#4f46e5"); t.dumpReference = Color(hex: "#9ca3b0"); t.dumpProperty = Color(hex: "#4b5563")
        t.dumpMeta = Color(hex: "#a855f7"); t.dumpKey = Color(hex: "#16a34a"); t.dumpIndex = Color(hex: "#3b82f6")
        t.dumpEllipsis = Color(hex: "#ea580c")
    }

    private static func make(_ name: String, dark: Bool, mono: Bool = false, blobs: [String]? = nil,
                             terminal: (String, String), _ c: [String]) -> AppTheme {
        let col = c.map { Color(hex: $0) }
        var t = AppTheme(name: name, isDark: dark, monospace: mono,
                         windowStart: col[0], windowEnd: col[1], header: col[2], text: col[3], secondaryText: col[4],
                         accent: col[5], hover: col[6], border: col[7], codeBackground: col[8], filename: col[9],
                         time: col[10], separator: col[11], snippetBackground: col[12], snippetActiveLine: col[13],
                         dumpText: .primary, dumpNumber: .primary, dumpString: .primary, dumpNote: .primary,
                         dumpReference: .primary, dumpProperty: .primary, dumpMeta: .primary, dumpKey: .primary,
                         dumpIndex: .primary, dumpEllipsis: .primary,
                         terminalBackground: NSColor(Color(hex: terminal.0)),
                         terminalForeground: NSColor(Color(hex: terminal.1)))
        if dark { darkDump(&t) } else { lightDump(&t) }
        if let blobs {
            t.glass = true
            t.blobs = blobs.map { Color(hex: $0) }
        }
        return t
    }

    //                                                                windowStart windowEnd  header     text       secondary  accent     hover        border       code         filename   time       separator  snippetBg  snippetActive
    static let snowflake = make("Snowflake", dark: true, blobs: ["#0b1e3a", "#123a6b", "#0e6e8c"], terminal: ("#0b1e3a", "#e6eef8"),
                                ["#0b1e3a", "#123a6b", "#0b1e3a", "#ffffff", "#ffffff9e", "#3ba7ff", "#ffffff12", "#ffffff1a", "#ffffff0d", "#9fb3cc", "#9fb3cc", "#3ba7ff", "#123a6b", "#1d5a9e"])
    static let snowflakeLight = make("Snowflake Light", dark: false, blobs: ["#ddefff", "#bfe0ff", "#c9f4f2"], terminal: ("#ffffff", "#111827"),
                                ["#ddefff", "#bfe0ff", "#ddefff", "#111827", "#1118279e", "#3ba7ff", "#ffffff66", "#0000000f", "#0000000a", "#4b6584", "#4b6584", "#3ba7ff", "#eef6ff", "#cfe6ff"])
    static let midnight  = make("Midnight", dark: true, terminal: ("#100322", "#e6e0f5"),
                                ["#14052e", "#1c0840", "#110425", "#ffffff", "#a897d3", "#ff6a00", "#ffffff0d", "#493b6d", "#ffffff0d", "#8e81b1", "#8e81b1", "#ff6a00", "#34245c", "#4c00c7"])
    static let daylight  = make("Daylight", dark: false, terminal: ("#ffffff", "#1a1a1a"),
                                ["#ffffff", "#ffffff", "#e6e6e6", "#000000", "#553b97", "#ff6a00", "#f2f2f233", "#a1a1aa4d", "#f2f2f2", "#847a99", "#847a99", "#ff6a00", "#f2f2f2", "#e0d1f5"])
    static let hackerman = make("Hackerman", dark: true, mono: true, terminal: ("#000000", "#52ff33"),
                                ["#000000", "#000000", "#000000", "#52ff33", "#4bac39", "#5ada44", "#061504", "#194610", "#ffffff0d", "#4bac39", "#4bac39", "#52ff33", "#061504", "#194610"])
    static let artisan   = make("Artisan", dark: false, terminal: ("#ffffff", "#21201c"),
                                ["#ffffff", "#ffffff", "#e6e6e6", "#21201c", "#82827d", "#f72f02", "#dbdad726", "#e6e6e6", "#f2f2f2", "#82827d", "#82827d", "#f72f02", "#ffffff", "#ffe1db"])
    static let vishal    = make("Vishal", dark: false, terminal: ("#ffffff", "#05038c"),
                                ["#ffffff", "#ffffff", "#f2f2f2", "#05038c", "#00000066", "#ff8f1f", "#f2f2f266", "#a1a1aa4d", "#f2f2f2", "#847a99", "#847a99", "#ff6a00", "#f2f2f2", "#e0d1f5"])
}

/// Window background. Glass themes (Snowflake) draw drifting gradient blobs over a translucent
/// base, like Snowflake Desktop; flat themes draw their gradient with a slow drifting glow.
/// `tint` pushes the background towards a color.
struct ThemeBackground: View {
    var tint: Color? = nil
    @State private var phase = false

    var body: some View {
        let store = ThemeStore.shared
        let theme = store.theme
        Group {
            if theme.glass {
                GlassGradientBackground(theme: theme, tint: tint, animated: store.animatedBackground)
            } else {
                flat(theme, animated: store.animatedBackground)
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder private func flat(_ theme: AppTheme, animated: Bool) -> some View {
        ZStack {
            if theme.isDark {
                LinearGradient(colors: [theme.windowStart, theme.windowEnd], startPoint: .top, endPoint: .bottom)
            } else {
                theme.pageBackground
            }
            if animated && theme.isDark && !theme.monospace {
                RadialGradient(colors: [theme.accent.opacity(0.10), .clear], center: phase ? .topTrailing : .bottomLeading,
                               startRadius: 10, endRadius: 520)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) { phase.toggle() }
                    }
            }
            if let tint { tint.opacity(0.14) }
        }
    }
}

/// Snowflake Desktop's background: four soft blobs drifting slowly over the native window material.
private struct GlassGradientBackground: View {
    let theme: AppTheme
    let tint: Color?
    let animated: Bool

    var body: some View {
        let ws = NSWorkspace.shared
        let reduceTransparency = ws.accessibilityDisplayShouldReduceTransparency
        let still = !animated || ws.accessibilityDisplayShouldReduceMotion
        let colors = theme.blobs
        ZStack {
            if reduceTransparency {
                theme.isDark ? Color(hex: "#111318") : Color(hex: "#f5f6f8")
            } else {
                VisualEffectBackground()
            }
            TimelineView(.animation(minimumInterval: 1 / 30, paused: still)) { context in
                let t = still ? 0 : context.date.timeIntervalSinceReferenceDate
                Canvas { ctx, size in
                    // A tint (the project's color) takes over two of the four blobs.
                    let blobs: [(Color, Double, Double, Double)] = [
                        (colors[0], 0.20, 0.25, 0.0),
                        (tint ?? colors[1], 0.80, 0.30, 2.1),
                        (colors[2], 0.50, 0.85, 4.2),
                        (tint ?? colors[1], 0.85, 0.85, 1.3),
                    ]
                    let radius = max(size.width, size.height) * 0.65
                    for (color, x, y, phase) in blobs {
                        let cx = size.width * (x + 0.06 * sin(t / 9 + phase))
                        let cy = size.height * (y + 0.06 * cos(t / 11 + phase))
                        let rect = CGRect(x: cx - radius / 2, y: cy - radius / 2, width: radius, height: radius)
                        ctx.fill(
                            Path(ellipseIn: rect),
                            with: .radialGradient(
                                Gradient(colors: [color.opacity(theme.isDark ? 0.5 : 0.6), color.opacity(0)]),
                                center: CGPoint(x: cx, y: cy),
                                startRadius: 0,
                                endRadius: radius / 2
                            )
                        )
                    }
                }
            }
            .blur(radius: 40)
            .opacity(reduceTransparency ? 0.4 : 0.7)
            // Soft wash of the tint from the top, like Snowflake Desktop's dashboard.
            if let tint {
                LinearGradient(colors: [tint.opacity(0.10), tint.opacity(0.03), .clear], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.8), value: tint)
    }
}

/// Native translucent material behind the window content.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}
