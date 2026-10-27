import AppKit
import DumpKit
import SwiftUI

struct DumpRowView: View {
    @Environment(AppState.self) private var appState
    @Environment(DumpSession.self) private var session
    let entry: DumpEntry
    let count: Int
    @State private var hovering = false

    private var service: DumpService { appState.dumpService }
    private var theme: AppTheme { ThemeStore.shared.theme }

    private var fontSize: CGFloat {
        switch entry.size {
        case "sm", "small": return 11
        case "lg", "large": return 17
        default: return service.compactUI ? 12 : 13
        }
    }

    var body: some View {
        if entry.logType == .separator {
            DumpSeparatorRow()
        } else {
            row
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 0) {
            if service.showColorIndicator {
                Rectangle()
                    .fill(entry.color.map { DumpColor.color($0) } ?? theme.border)
                    .frame(width: 4)
            }
            VStack(alignment: .leading, spacing: service.compactUI ? 2 : 6) {
                header
                if !entry.collapsed {
                    DumpPayloadView(entry: entry)
                        .font(.system(size: fontSize, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, service.compactUI ? 6 : 10)
            .padding(.vertical, service.compactUI ? 4 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(hovering ? theme.hover : theme.cardBackground)
        .background(entry.logType == .exception ? Color(hex: "#f872721a") : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.border))
        .onHover { hovering = $0 }
        .contextMenu { menu }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                session.store.toggleCollapsed(entry.id)
            } label: {
                Image(systemName: entry.collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 10)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if !service.showLabels {
                EmptyView()
            } else if let label = entry.label, !label.isEmpty {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background((entry.color.map { DumpColor.color($0) } ?? .secondary).opacity(0.25), in: Capsule())
            } else if service.labelledColors, let color = entry.color {
                Text(color).font(.system(size: 11, weight: .semibold)).foregroundStyle(DumpColor.color(color))
            }

            Text(typeTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            if count > 1 {
                Text("×\(count)")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 5)
                    .background(theme.accent.opacity(0.25), in: Capsule())
            }

            Spacer(minLength: 8)

            // Always laid out, only faded in on hover: adding them on hover changes the row's size,
            // which moves the row under the pointer and makes hover flicker.
            HStack(spacing: 8) {
                Button { copy() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).help("Copy")
                Button { session.store.removeEntry(entry.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Remove")
            }
            .font(.system(size: 11))
            .frame(height: 14)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .accessibilityHidden(!hovering)

            if service.showFilename, let file = entry.origin.file {
                Button {
                    service.open(file: file, line: entry.origin.line ?? 1, target: session.target)
                } label: {
                    Text(originLabel(file: file))
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(theme.filename)
                }
                .buttonStyle(.plain)
                .help("\(file):\(entry.origin.line ?? 0) — open in \(service.editor.displayName)")
            }
            if let host = entry.origin.hostname, session.store.knownHosts.count > 1 {
                Text(host).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if service.showTimestamp {
                Text(entry.createdAt, format: .dateTime.hour().minute().second())
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(theme.time)
            }
        }
    }

    private func originLabel(file: String) -> String {
        let name = (file as NSString).lastPathComponent
        return entry.origin.line.map { "\(name):\($0)" } ?? name
    }

    private var typeTitle: String {
        switch entry.logType {
        case .log: return ""
        case .custom: return entry.content["label"]?.string ?? ""
        case .executedQuery: return "Query"
        case .exception: return "Exception"
        case .table: return entry.content["label"]?.string ?? "Table"
        case .jsonString, .json: return "JSON"
        case .carbon: return "Carbon"
        case .measure: return "Measure"
        case .caller: return "Caller"
        case .trace: return "Trace"
        case .mailable: return "Mailable"
        case .eloquentModel: return "Model"
        case .event: return "Event"
        case .jobEvent: return "Job event"
        case .applicationLog: return "Log"
        case .view: return "View"
        case .response: return "Response"
        case .lock: return "Paused"
        case .customHtml: return "HTML"
        case .customMarkdown: return "Markdown"
        case .customMermaid: return "Mermaid diagram"
        default: return entry.type == DumpStore.dsTableType ? "Table" : entry.type
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Copy") { copy() }
        if let file = entry.origin.file {
            Button("Open in \(service.editor.displayName)") {
                service.open(file: file, line: entry.origin.line ?? 1, target: session.target)
            }
            Button("Copy Path") {
                setPasteboard("\(service.localPath(for: file, target: session.target)):\(entry.origin.line ?? 0)")
            }
        }
        Button(entry.collapsed ? "Expand" : "Collapse") { session.store.toggleCollapsed(entry.id) }
        Divider()
        Button("Remove") { session.store.removeEntry(entry.id) }
    }

    private func copy() { setPasteboard(entry.copyText) }

    private func setPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct DumpSeparatorRow: View {
    var body: some View {
        let color = ThemeStore.shared.theme.separator
        HStack {
            Rectangle().fill(color).frame(height: 1)
            Image(systemName: "scissors").font(.caption).foregroundStyle(color)
            Rectangle().fill(color).frame(height: 1)
        }
        .padding(.vertical, 4)
    }
}

/// Colors clients attach to a message (`->green()`, `->orange()`, …).
enum DumpColor {
    static let names = ["green", "orange", "red", "purple", "blue", "gray"]

    static func color(_ name: String?) -> Color {
        switch name {
        case "green": return .green
        case "orange": return .orange
        case "red": return .red
        case "purple": return .purple
        case "blue": return .blue
        case "gray", "grey": return .gray
        default: return .clear
        }
    }
}
