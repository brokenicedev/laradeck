import DBEngineKit
import SwiftUI

extension EngineKind {
    var tint: Color {
        switch self {
        case .postgresql: return .blue
        case .mysql: return .orange
        case .redis: return .purple
        }
    }
}

extension ServiceStatus {
    var color: Color {
        switch self {
        case .running: return .green
        case .starting: return .yellow
        case .stopped: return .gray
        }
    }

    var label: String {
        switch self {
        case .running: return "Running"
        case .starting: return "Starting"
        case .stopped: return "Stopped"
        }
    }
}

/// Detail column for the sidebar's "Databases" entry.
struct DatabasesView: View {
    @Environment(AppState.self) private var appState
    @State private var showingNewDatabase = false
    /// Projects whose `.env` points at each service, recomputed when the list changes.
    @State private var linkedProjects: [UUID: [String]] = [:]

    private var databases: DatabaseManager { appState.databaseManager }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if let error = databases.error {
                    NoticeBanner(tone: .error, message: error) {
                        databases.error = nil
                    }
                }

                if databases.rows.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        ForEach(databases.rows) { row in
                            DatabaseRowView(row: row, linkedProjects: linkedProjects[row.id] ?? [])
                            if row.id != databases.rows.last?.id {
                                Divider().padding(.leading, 52)
                            }
                        }
                    }
                    .laradeckCard()
                }

                Text("Servers run in the background under launchd: they keep running when you quit Laradeck and restart if they crash.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(LaradeckTheme.pageBackground)
        .laradeckTitle("Databases")
        .detailCloseButton(help: "Close databases") { appState.showingDatabases = false }
        .sheet(isPresented: $showingNewDatabase) {
            NewDatabaseSheet()
        }
        .task(id: databases.rows.map(\.service)) {
            linkedProjects = Self.linkedProjects(projects: appState.projects, services: databases.rows.map(\.service))
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Databases")
                    .font(.largeTitle.weight(.semibold))
                Text("Local PostgreSQL, MySQL and Redis servers from Homebrew.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showingNewDatabase = true
            } label: {
                Label("New Database", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No databases yet")
                .font(.title3.weight(.semibold))
            Text("Create a PostgreSQL, MySQL or Redis server for your native Laravel projects.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("New Database…") { showingNewDatabase = true }
                .buttonStyle(.laradeckOutline)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .laradeckCard()
    }

    nonisolated static func linkedProjects(projects: [Project], services: [Service]) -> [UUID: [String]] {
        var result: [UUID: [String]] = [:]
        for project in projects {
            for requirement in ProjectDatabaseLink.requirements(for: project) {
                if let service = ProjectDatabaseLink.service(for: requirement, in: services) {
                    result[service.id, default: []].append(project.name)
                }
            }
        }
        return result
    }
}

private struct DatabaseRowView: View {
    @Environment(AppState.self) private var appState
    let row: DatabaseManager.Row
    let linkedProjects: [String]
    @State private var confirmingDelete = false

    private var databases: DatabaseManager { appState.databaseManager }
    private var service: Service { row.service }
    private var isBusy: Bool { databases.busy.contains(row.id) }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "cylinder.split.1x2.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(service.kind.tint)
                    .frame(width: 28, height: 28)
                StatusDotView(color: row.status.color, size: 9, showsBorder: true)
                    .offset(x: 3, y: 3)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(service.name).font(.headline)
                    PortBadgeView(ports: [service.port])
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let line = databases.progress[row.id] {
                    Text(line)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if isBusy {
                ProgressView().controlSize(.small)
            }

            if DatabaseManager.hasTablePlus {
                Button {
                    databases.openInTablePlus(service)
                } label: {
                    Image(systemName: "tablecells")
                }
                .buttonStyle(.laradeckIcon())
                .help("Open in TablePlus")
            }

            Button {
                databases.openShell(service, terminal: appState.preferredTerminal)
            } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(.laradeckIcon())
            .help("Open \(service.kind.clientName) in \(appState.preferredTerminal.displayName)")

            Button {
                databases.toggle(row)
            } label: {
                Image(systemName: row.status == .stopped ? "play.fill" : "stop.fill")
            }
            .buttonStyle(.laradeckIcon(accent: row.status == .stopped ? .green : .red))
            .disabled(isBusy)
            .help(row.status == .stopped ? "Start" : "Stop")

            moreMenu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { appState.selectedDatabaseId = row.id }
        .contextMenu { DatabaseMenuItems(row: row) { confirmingDelete = true } }
        .databaseDeleteConfirmation(service, isPresented: $confirmingDelete) {
            databases.delete(service)
        }
    }

    private var subtitle: String {
        var parts = ["\(service.kind.displayName) \(service.version)", row.status.label]
        if !databases.isHomebrew(service) { parts.append("local binaries") }
        if service.autoStart { parts.append("starts with Laradeck") }
        if service.isShared { parts.append("shared on network") }
        if !linkedProjects.isEmpty { parts.append("used by \(linkedProjects.joined(separator: ", "))") }
        return parts.joined(separator: " · ")
    }

    private var moreMenu: some View {
        Menu {
            DatabaseMenuItems(row: row) { confirmingDelete = true }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
