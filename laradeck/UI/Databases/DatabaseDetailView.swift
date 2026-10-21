import DBEngineKit
import SwiftUI

/// Same actions everywhere a database appears (sidebar, overview, detail).
struct DatabaseMenuItems: View {
    @Environment(AppState.self) private var appState
    let row: DatabaseManager.Row
    let onDelete: () -> Void

    private var databases: DatabaseManager { appState.databaseManager }
    private var service: Service { row.service }

    var body: some View {
        Button(row.status == .stopped ? "Start" : "Stop") { databases.toggle(row) }
            .disabled(databases.busy.contains(row.id))
        Divider()
        if DatabaseManager.hasTablePlus {
            Button("Open in TablePlus") { databases.openInTablePlus(service) }
        }
        Button("Open \(service.kind.clientName) in \(appState.preferredTerminal.displayName)") {
            databases.openShell(service, terminal: appState.preferredTerminal)
        }
        Button("Copy Connection URL") { databases.copyURL(service) }
        Divider()
        Button("Show Log") { databases.openLog(service) }
        Button("Show Data in Finder") { databases.revealData(service) }
        Toggle("Start When Laradeck Opens", isOn: Binding(
            get: { service.autoStart },
            set: { databases.setAutoStart(service, $0) }
        ))
        if service.kind.supportsNetworkShare {
            Toggle("Share on Network", isOn: Binding(
                get: { service.isShared },
                set: { databases.setNetworkShare(service, $0) }
            ))
            .disabled(databases.busy.contains(row.id))
        }
        if !databases.isHomebrew(service) {
            Button("Use Homebrew Binaries") { databases.switchToHomebrew(service) }
        }
        Divider()
        Button("Delete…", role: .destructive, action: onDelete)
    }
}

extension View {
    /// Confirmation shown before deleting a database service.
    func databaseDeleteConfirmation(_ service: Service?, isPresented: Binding<Bool>, onDelete: @escaping () -> Void) -> some View {
        confirmationDialog("Delete \(service?.name ?? "database")?", isPresented: isPresented) {
            Button("Delete and Move Data to Trash", role: .destructive, action: onDelete)
        } message: {
            Text("The server is stopped and its data folder goes to the Trash.")
        }
    }
}

extension EngineKind {
    var clientName: String {
        switch self {
        case .postgresql: return "psql"
        case .mysql: return "mysql"
        case .redis: return "redis-cli"
        }
    }
}

/// Detail column for one database selected in the sidebar.
struct DatabaseDetailView: View {
    @Environment(AppState.self) private var appState
    let row: DatabaseManager.Row

    @State private var confirmingDelete = false
    @State private var logTail = ""
    @State private var cleared = ClearedLog()
    /// Projects whose `.env` points here, with their `DB_DATABASE` (nil for Redis).
    @State private var linkedProjects: [(project: Project, database: String?)] = []

    private var databases: DatabaseManager { appState.databaseManager }
    private var service: Service { row.service }
    private var isBusy: Bool { databases.busy.contains(row.id) }
    private var isStarting: Bool {
        if case .starting = row.status { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    if let error = databases.error {
                        NoticeBanner(tone: .error, message: error) { databases.error = nil }
                    }

                    infoCard
                    NetworkShareCard(row: row)
                    if !linkedProjects.isEmpty { projectsCard }
                    if service.kind != .redis {
                        ServerDatabasesCard(row: row, linkedProjects: linkedProjects)
                    }
                    }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            LogPanel(title: "Log · \(service.kind.logFile(service).lastPathComponent)",
                     onClear: { cleared.clear(logTail) }) {
                Button("Open File") { databases.openLog(service) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(LogPanelStyle.secondary)
            } content: {
                LogTextView(text: cleared.visible(logTail))
            }
        }
        .background(LaradeckTheme.pageBackground)
        .navigationTitle(service.name)
        .detailCloseButton(help: "Close database") { appState.selectedDatabaseId = nil }
        .databaseDeleteConfirmation(service, isPresented: $confirmingDelete) {
            appState.selectedDatabaseId = nil
            databases.delete(service)
        }
        // Re-read the log and linked projects whenever the status changes, and every few seconds.
        .task(id: row) {
            linkedProjects = appState.projects.compactMap { project in
                let match = ProjectDatabaseLink.requirements(for: project).first {
                    ProjectDatabaseLink.service(for: $0, in: [service]) != nil
                }
                return match.map { (project, $0.database) }
            }
            await databases.loadDatabaseNames(service)
            while !Task.isCancelled {
                let manager = databases.manager
                let file = databases.logFile(service)
                logTail = await Task.detached { manager.tail(file, lines: 40) }.value
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "cylinder.split.1x2.fill")
                .font(.system(size: 34))
                .foregroundStyle(service.kind.tint)

            VStack(alignment: .leading, spacing: 4) {
                Text(service.name)
                    .font(.title.weight(.semibold))
                HStack(spacing: 6) {
                    StatusDotView(color: row.status.color, size: 8, pulsing: isStarting)
                    Text(statusText)
                        .foregroundStyle(.secondary)
                    PortBadgeView(ports: [service.port])
                }
            }

            Spacer()

            if isBusy {
                ProgressView().controlSize(.small)
            }

            if DatabaseManager.hasTablePlus {
                Button {
                    databases.openInTablePlus(service)
                } label: {
                    Label("TablePlus", systemImage: "tablecells")
                }
                .buttonStyle(.laradeckOutline)
            }

            Button {
                databases.openShell(service, terminal: appState.preferredTerminal)
            } label: {
                Label(service.kind.clientName, systemImage: "terminal")
            }
            .buttonStyle(.laradeckOutline)

            Button {
                databases.toggle(row)
            } label: {
                Label(row.status == .stopped ? "Start" : "Stop",
                      systemImage: row.status == .stopped ? "play.fill" : "stop.fill")
            }
            .buttonStyle(.laradeckOutline(accent: row.status == .stopped ? .green : .red))
            .disabled(isBusy)

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

    private var statusText: String {
        if let line = databases.progress[row.id] { return line }
        if case let .running(pid) = row.status { return "Running · pid \(pid)" }
        return row.status.label
    }

    // MARK: Cards

    private var infoCard: some View {
        VStack(spacing: 0) {
            infoRow("Engine", "\(service.kind.displayName) \(service.version)")
            Divider()
            infoRow("Connection", service.kind.connectionURL(port: service.port, name: service.name)
                .components(separatedBy: "?").first ?? "", copy: service.connectionURL)
            if let user = service.kind.defaultUser {
                Divider()
                infoRow("User", "\(user) (no password)")
            }
            Divider()
            infoRow("Binaries", databases.isHomebrew(service) ? "Homebrew · \(service.binariesPath)" : service.binariesPath)
            Divider()
            HStack {
                Text("Data")
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                Text(service.dataPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button("Show in Finder") { databases.revealData(service) }
                    .buttonStyle(.link)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Divider()
            HStack {
                Text("Start when Laradeck opens")
                Spacer()
                Toggle("", isOn: Binding(
                    get: { service.autoStart },
                    set: { databases.setAutoStart(service, $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .laradeckCard()
    }

    private func infoRow(_ label: String, _ value: String, copy: String? = nil) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            if let copy {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copy, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.laradeckIcon())
                .help("Copy connection URL")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var projectsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Used by")
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(linkedProjects, id: \.project.id) { link in
                    let project = link.project
                    HStack(spacing: 10) {
                        Button {
                            appState.selectedProjectId = project.id
                        } label: {
                            HStack(spacing: 10) {
                                ProjectFaviconView(project: project, size: 22)
                                Text(project.name)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if let database = link.database {
                            DatabaseNameBadge(name: database, service: service)
                        }
                        Button {
                            appState.selectedProjectId = project.id
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(.laradeckIcon())
                        .help("Open \(project.name)")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    if project.id != linkedProjects.last?.project.id {
                        Divider().padding(.leading, 46)
                    }
                }
            }
            .laradeckCard()
        }
    }

}

/// Every database inside a PostgreSQL / MySQL server, with the projects that use each one.
private struct ServerDatabasesCard: View {
    @Environment(AppState.self) private var appState
    let row: DatabaseManager.Row
    let linkedProjects: [(project: Project, database: String?)]

    @State private var showingSystem = false
    @State private var showingCreate = false
    @State private var newName = ""

    private var databases: DatabaseManager { appState.databaseManager }
    private var service: Service { row.service }

    /// The engine's own databases, hidden unless asked for.
    private static let systemNames: Set<String> = ["postgres", "information_schema", "mysql", "performance_schema", "sys"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Databases")
                    .font(.headline)
                Spacer()
                if databases.databaseNames[service.id] != nil {
                    Toggle("System", isOn: $showingSystem)
                        .toggleStyle(.checkbox)
                        .font(.callout)
                    Button("New…") {
                        newName = ""
                        showingCreate = true
                    }
                    .buttonStyle(.link)
                }
            }
            content
                .laradeckCard()
        }
        .alert("New Database on \(service.name)", isPresented: $showingCreate) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { databases.createDatabase(name, in: service) }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let names = databases.databaseNames[service.id] {
            let visible = names.filter { showingSystem || !Self.systemNames.contains($0) }.sorted()
            if visible.isEmpty {
                placeholder("No databases yet")
            } else {
                VStack(spacing: 0) {
                    ForEach(visible, id: \.self) { name in
                        databaseRow(name)
                        if name != visible.last {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
            }
        } else {
            placeholder(row.isRunning ? "Loading…" : "Start the server to see its databases")
        }
    }

    private func databaseRow(_ name: String) -> some View {
        let users = linkedProjects.filter { $0.database == name }.map(\.project)
        return HStack(spacing: 10) {
            Image(systemName: Self.systemNames.contains(name) ? "gearshape" : "tablecells")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(name)
                .font(.body.monospaced())
                .textSelection(.enabled)
            ForEach(users) { project in
                Button {
                    appState.selectedProjectId = project.id
                } label: {
                    Text(project.name)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Used by \(project.name)")
            }
            Spacer()
            if DatabaseManager.hasTablePlus {
                Button {
                    databases.openInTablePlus(service, database: name)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.laradeckIcon())
                .help("Open \(name) in TablePlus")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
    }
}
