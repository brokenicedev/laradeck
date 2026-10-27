import DumpKit
import SwiftUI

/// Label for the Dumps button, with the unread count as an inline pill.
struct DumpsButtonLabel: View {
    let unread: Int

    var body: some View {
        Label {
            HStack(spacing: 5) {
                Text("Dumps")
                if unread > 0 {
                    Text(unread > 99 ? "99+" : "\(unread)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.red))
                }
            }
        } icon: {
            Image(systemName: "ladybug")
        }
    }
}

/// Compact dashboard card: how many dumps this project has, and a button to open them.
/// Hidden until the project has received at least one dump.
struct ProjectDumpsSummary: View {
    @Environment(AppState.self) private var appState
    let project: Project
    let onOpen: () -> Void

    var body: some View {
        let target = DumpTarget.project(project.id)
        let service = appState.dumpService
        if let session = service.existingSession(for: target), !session.store.currentScreen.entries.isEmpty {
            let total = session.store.currentScreen.entries.count
            HStack(spacing: 12) {
                Image(systemName: "ladybug")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dumps").font(.headline)
                    Text(subtitle(total: total, unread: session.unreadCount, detached: service.isDetached(target)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open", action: onOpen)
                    .buttonStyle(.laradeckOutline)
            }
            .padding(14)
            .laradeckCard()
        }
    }

    private func subtitle(total: Int, unread: Int, detached: Bool) -> String {
        var parts = ["\(total) message\(total == 1 ? "" : "s")"]
        if unread > 0 { parts.append("\(unread) new") }
        if detached { parts.append("in its own window") }
        return parts.joined(separator: " · ")
    }
}

/// Bug icon with the unread count, next to the project in the sidebar. Red when an exception
/// (or a red message) arrived. Click opens the project's Dumps.
struct SidebarDumpsBadge: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    let project: Project

    var body: some View {
        let target = DumpTarget.project(project.id)
        let service = appState.dumpService
        if let session = service.existingSession(for: target), session.unreadCount > 0 {
            let hasErrors = session.unreadErrorCount > 0
            let tint = hasErrors ? Color.red : Color.accentColor
            Button {
                open(target)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: hasErrors ? "ladybug.fill" : "ladybug")
                        .font(.system(size: 13))
                    Text(session.unreadCount > 99 ? "99+" : "\(session.unreadCount)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(tint))
                }
                .foregroundStyle(tint)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(helpText(unread: session.unreadCount, errors: session.unreadErrorCount))
        }
    }

    private func open(_ target: DumpTarget) {
        if appState.dumpService.isDetached(target) {
            DumpsWindow.open(target, service: appState.dumpService, openWindow: openWindow)
        } else {
            appState.selectedProjectId = project.id
            appState.pendingDumpsOpen = project.id
        }
    }

    private func helpText(unread: Int, errors: Int) -> String {
        var text = "\(unread) new dump\(unread == 1 ? "" : "s")"
        if errors > 0 { text += ", \(errors) with errors" }
        return text + " — click to open"
    }
}

/// Sidebar toolbar button: opens the Dumps window, on the selected project when there is one.
struct SidebarDumpsButton: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let service = appState.dumpService
        let unread = service.totalUnread
        Button {
            let target = appState.selectedProjectId.map(DumpTarget.project)
                ?? service.windowTarget
                ?? service.activeSessions.first?.target
            DumpsWindow.open(target, service: service, openWindow: openWindow)
        } label: {
            Label("Dumps", systemImage: unread > 0 ? "ladybug.fill" : "ladybug")
        }
        .help(unread > 0 ? "Open Dumps window (\(unread) new)" : "Open Dumps window")
    }
}
