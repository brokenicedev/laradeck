import DBEngineKit
import SwiftUI

/// Detail column for a database container in a project's Compose / Sail stack.
struct DockerDatabaseDetailView: View {
    @Environment(AppState.self) private var appState
    let database: DockerDatabase

    /// nil while unknown (container stopped, or the client couldn't connect).
    @State private var names: [String]?
    @State private var logTail = ""
    @State private var cleared = ClearedLog()
    @State private var showingSystem = false
    @State private var showingCreate = false
    @State private var newName = ""
    @State private var revealPassword = false
    @State private var working = false
    @State private var error: String?

    private var docker: DockerManager { appState.dockerManager }
    private var env: [String: String] { LaravelDetector.readEnvFile(at: database.projectPath) }
    private var isRedis: Bool { database.kind == .redis }
    /// The project's own `DB_DATABASE` (or Laravel's default).
    private var projectDatabase: String? {
        isRedis ? nil : (env["DB_DATABASE"].flatMap { $0.isEmpty ? nil : $0 } ?? "laravel")
    }

    private static let systemNames: Set<String> = ["postgres", "information_schema", "mysql", "performance_schema", "sys"]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if let error {
                        NoticeBanner(tone: .error, message: error) { self.error = nil }
                    }
                    if !docker.isDaemonRunning {
                        NoticeBanner(tone: .warning, message: DockerManager.daemonUnavailableMessage)
                    }
                    infoCard
                    if !isRedis { databasesCard }
                    }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            LogPanel(title: "Log · docker compose logs \(database.service)",
                     onClear: { cleared.clear(logTail) }) {
                LogTextView(text: cleared.visible(logTail))
            }
        }
        .background(LaradeckTheme.pageBackground)
        .navigationTitle("\(database.service) · \(database.projectName)")
        .detailCloseButton(help: "Close database") { appState.selectedDockerDatabaseId = nil }
        .alert("New Database in \(database.service)", isPresented: $showingCreate) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { create(newName.trimmingCharacters(in: .whitespaces)) }
        }
        // Reload when the container starts/stops, then keep the log fresh.
        .task(id: database.isRunning) {
            names = nil
            if database.isRunning, !isRedis {
                names = await docker.databaseNames(in: database)
            }
            while !Task.isCancelled {
                logTail = await docker.logTail(of: database)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "cylinder.split.1x2.fill")
                .font(.system(size: 34))
                .foregroundStyle(database.kind.tint)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Circle().fill(Color(red: 0.11, green: 0.51, blue: 0.93)))
                        .offset(x: 6, y: 4)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(database.service)
                    .font(.title.weight(.semibold))
                HStack(spacing: 6) {
                    StatusDotView(color: database.isRunning ? .green : .gray, size: 8)
                    Text("\(database.isRunning ? "Running" : "Stopped") · \(database.kind.displayName) in Docker")
                        .foregroundStyle(.secondary)
                    if let port = database.hostPort {
                        PortBadgeView(ports: [port])
                    }
                }
            }

            Spacer()

            if working || docker.isBusy(database.projectId) {
                ProgressView().controlSize(.small)
            }

            if DatabaseManager.hasTablePlus {
                Button {
                    appState.openDockerDatabaseInTablePlus(database)
                } label: {
                    Label("TablePlus", systemImage: "tablecells")
                }
                .buttonStyle(.laradeckOutline)
                .disabled(!database.isRunning || database.hostPort == nil)
            }

            Button {
                TerminalLauncher.openContainerShell(appState.preferredTerminal,
                                                    projectPath: database.projectPath,
                                                    service: database.service)
            } label: {
                Label("Shell", systemImage: "terminal")
            }
            .buttonStyle(.laradeckOutline)
            .disabled(!database.isRunning)

            Button {
                appState.toggleDockerDatabase(database)
            } label: {
                Label(database.isRunning ? "Stop" : "Start",
                      systemImage: database.isRunning ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.laradeckOutline(accent: database.isRunning ? .red : .green))
            .disabled(!docker.isDaemonRunning || docker.isBusy(database.projectId))
        }
    }

    // MARK: Cards

    private var infoCard: some View {
        VStack(spacing: 0) {
            HStack {
                label("Project")
                Button {
                    appState.selectedProjectId = database.projectId
                } label: {
                    HStack(spacing: 4) {
                        Text(database.projectName)
                        Image(systemName: "chevron.right").font(.caption)
                    }
                }
                .buttonStyle(.link)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Divider()
            infoRow("Service", "\(database.service) (docker compose)")
            Divider()
            infoRow("Host port", database.hostPort.map { "127.0.0.1:\($0)" } ?? "not published")
            if !isRedis {
                Divider()
                infoRow("User", env["DB_USERNAME"] ?? "—")
                Divider()
                passwordRow(env["DB_PASSWORD"])
            } else if let password = env["REDIS_PASSWORD"], password != "null", !password.isEmpty {
                Divider()
                passwordRow(password)
            }
        }
        .laradeckCard()
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(width: 110, alignment: .leading)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            label(title)
            Text(value)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func passwordRow(_ password: String?) -> some View {
        HStack {
            label("Password")
            if let password, !password.isEmpty {
                Text(revealPassword ? password : String(repeating: "•", count: min(password.count, 12)))
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                Spacer()
                Button {
                    revealPassword.toggle()
                } label: {
                    Image(systemName: revealPassword ? "eye.slash" : "eye")
                }
                .buttonStyle(.laradeckIcon())
                .help(revealPassword ? "Hide" : "Show")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(password, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.laradeckIcon())
                .help("Copy password")
            } else {
                Text("(empty)").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var databasesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Databases")
                    .font(.headline)
                Spacer()
                if names != nil {
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
            Group {
                if let names {
                    databaseList(names)
                } else {
                    Text(database.isRunning ? "Loading…" : "Start the container to see its databases")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            }
            .laradeckCard()
        }
    }

    @ViewBuilder
    private func databaseList(_ names: [String]) -> some View {
        let visible = names.filter { showingSystem || !Self.systemNames.contains($0) }
        VStack(spacing: 0) {
            // The project's DB_DATABASE first, flagged when it's missing.
            if let wanted = projectDatabase, !names.contains(wanted) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .frame(width: 18)
                    Text(wanted).font(.body.monospaced())
                    Text("DB_DATABASE of \(database.projectName) doesn't exist")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Create") { create(wanted) }
                        .buttonStyle(.laradeckOutline(accent: .orange, compact: true))
                        .disabled(working)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                if !visible.isEmpty { Divider().padding(.leading, 40) }
            }
            ForEach(visible, id: \.self) { name in
                HStack(spacing: 10) {
                    Image(systemName: Self.systemNames.contains(name) ? "gearshape" : "tablecells")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(name)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                    if name == projectDatabase {
                        Text(database.projectName)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .help("DB_DATABASE of \(database.projectName)")
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                if name != visible.last {
                    Divider().padding(.leading, 40)
                }
            }
            if visible.isEmpty && projectDatabase.map(names.contains) != false {
                Text("No databases yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        }
    }


    // MARK: Actions

    private func create(_ name: String) {
        guard !name.isEmpty else { return }
        working = true
        Task {
            let result = await docker.createDatabase(name, in: database)
            if !result.success {
                error = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            names = await docker.databaseNames(in: database)
            working = false
        }
    }
}
