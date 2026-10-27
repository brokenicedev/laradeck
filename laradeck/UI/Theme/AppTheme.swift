import AppKit
import SwiftUI

/// App-wide color theme. Five built-in themes, two dark and three light, plus a terminal-green one.
struct AppTheme: Equatable, Identifiable {
    var name: String
    var isDark: Bool
    var monospace = false

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
    var cardBackground: Color { isDark ? Color.white.opacity(0.045) : Color.white }

    /// Light themes have a white window; give the page a soft gray so white cards stand out.
    var pageBackground: Color { isDark ? windowStart : Color(white: 0.965) }

    static let all: [AppTheme] = [.midnight, .daylight, .hackerman, .artisan, .vishal]

    static func named(_ name: String) -> AppTheme {
        all.first { $0.name.lowercased() == name.lowercased() } ?? .midnight
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

    private static func make(_ name: String, dark: Bool, mono: Bool = false,
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
        return t
    }

    //                                                                windowStart windowEnd  header     text       secondary  accent     hover        border       code         filename   time       separator  snippetBg  snippetActive
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

/// Window background: theme gradient, a slow drifting glow when the animated background is on,
/// and an optional tint.
struct ThemeBackground: View {
    var tint: Color? = nil
    @State private var phase = false

    var body: some View {
        let store = ThemeStore.shared
        let theme = store.theme
        ZStack {
            if theme.isDark {
                LinearGradient(colors: [theme.windowStart, theme.windowEnd], startPoint: .top, endPoint: .bottom)
            } else {
                theme.pageBackground
            }
            if store.animatedBackground && theme.isDark && !theme.monospace {
                RadialGradient(colors: [theme.accent.opacity(0.10), .clear], center: phase ? .topTrailing : .bottomLeading,
                               startRadius: 10, endRadius: 520)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) { phase.toggle() }
                    }
            }
            if let tint { tint.opacity(0.14) }
        }
        .ignoresSafeArea()
    }
}
