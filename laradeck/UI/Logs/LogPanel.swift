import AppKit
import SwiftUI

/// Colors of the docked log panel: dark in both light and dark mode, like Xcode's console.
enum LogPanelStyle {
    static let nsBackground = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    static let nsForeground = NSColor(white: 0.86, alpha: 1)
    static let background = Color(nsColor: nsBackground)
    static let headerBackground = Color(white: 0.15)
    static let foreground = Color(nsColor: nsForeground)
    static let secondary = Color(white: 0.55)
    static let separator = Color(white: 1, opacity: 0.08)
}

/// Dark "Logs" panel docked at the bottom of a detail page: title, optional accessory
/// (e.g. a source picker), Clear, collapse; drag the top edge to resize.
struct LogPanel<Accessory: View, Content: View>: View {
    var title = "Logs"
    var onClear: (() -> Void)?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    @AppStorage("logPanelHeight") private var height: Double = 240
    @AppStorage("logPanelCollapsed") private var collapsed = false
    @State private var dragStartHeight: Double?

    init(title: String = "Logs", onClear: (() -> Void)? = nil,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.onClear = onClear
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            resizeHandle
            header
            if !collapsed {
                LogPanelStyle.separator.frame(height: 1)
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .frame(height: height)
            }
        }
        .background(LogPanelStyle.background)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { collapsed.toggle() }
            } label: {
                Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LogPanelStyle.secondary)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Show logs" : "Hide logs")

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LogPanelStyle.foreground)

            accessory()

            Spacer()

            if let onClear, !collapsed {
                Button("Clear", action: onClear)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(LogPanelStyle.secondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(LogPanelStyle.headerBackground)
    }

    /// Thin strip on the top edge; drag it to change the panel height.
    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.black.opacity(0.35))
            .frame(height: 1)
            .overlay {
                Color.clear
                    .frame(height: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                guard !collapsed else { return }
                                let start = dragStartHeight ?? height
                                dragStartHeight = start
                                height = min(max(start - value.translation.height, 100), 700)
                            }
                            .onEnded { _ in dragStartHeight = nil }
                    )
            }
    }
}

/// Plain-text log (DB server log, `docker compose logs`) in the panel: monospaced,
/// errors in red and warnings in orange, follows the bottom.
struct LogTextView: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(styled)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .defaultScrollAnchor(.bottom)
    }

    private var styled: AttributedString {
        guard !text.isEmpty else {
            var empty = AttributedString("No output yet.")
            empty.foregroundColor = LogPanelStyle.secondary
            return empty
        }
        var result = AttributedString()
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var part = AttributedString((index == 0 ? "" : "\n") + line)
            let upper = line.uppercased()
            if upper.contains("ERROR") || upper.contains("FATAL") || upper.contains("PANIC") {
                part.foregroundColor = Color(red: 1, green: 0.42, blue: 0.4)
            } else if upper.contains("WARN") {
                part.foregroundColor = Color(red: 1, green: 0.72, blue: 0.3)
            } else {
                part.foregroundColor = LogPanelStyle.foreground
            }
            result += part
        }
        return result
    }
}

/// "Clear" for logs that are re-read from a file / command: hides everything up to the
/// last line seen when Clear was pressed.
struct ClearedLog {
    private var marker: String?

    mutating func clear(_ current: String) {
        marker = current.split(separator: "\n").last.map(String.init)
    }

    func visible(_ text: String) -> String {
        guard let marker, let range = text.range(of: marker, options: .backwards) else { return text }
        return String(text[range.upperBound...]).trimmingCharacters(in: .newlines)
    }
}
