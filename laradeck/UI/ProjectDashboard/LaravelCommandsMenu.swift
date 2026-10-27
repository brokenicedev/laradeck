import SwiftUI

/// The project header's ".env" and "Artisan" dropdowns.
struct LaravelCommandsMenu: View {
    @Environment(AppState.self) private var appState

    let project: Project
    var onOpenEnv: () -> Void
    var onTaskSucceeded: () -> Void = {}

    @State private var insights = LaravelInsights()
    @State private var runningTask: ArtisanTask?
    @State private var pendingConfirmation: ArtisanTask?
    @State private var showingMigrateConfirmation = false
    @State private var successAlertMessage: String?
    @State private var lastFailure: ArtisanFailure?
    @State private var showingShareEnv = false
    @State private var showingReceiveEnv = false

    private struct ArtisanFailure: Equatable {
        let taskLabel: String
        let message: String
    }

    private var artisanTasks: [ArtisanTask] {
        ArtisanTask.allCases.filter { task in
            if task == .storageLink {
                return insights.storageLink != .linked
            }
            return true
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            envMenu
            if !artisanTasks.isEmpty {
                artisanMenu
            }
        }
        .task(id: project.id) {
            if let cached = appState.cachedLaravelInsights(for: project.id) {
                insights = cached
            } else {
                let loaded = LaravelInsightsService.loadInstant(project: project)
                insights = loaded
                appState.storeLaravelInsights(loaded, for: project.id)
            }
        }
        .sheet(isPresented: $showingShareEnv) {
            EnvShareHostView(project: project)
        }
        .sheet(isPresented: $showingReceiveEnv) {
            EnvReceiveView()
        }
        .confirmationDialog(
            "Run pending migrations for \(project.name)?",
            isPresented: $showingMigrateConfirmation,
            titleVisibility: .visible
        ) {
            Button("Run Migrations") {
                if let task = pendingConfirmation {
                    Task { await runTask(task) }
                }
                pendingConfirmation = nil
            }
            Button("Cancel", role: .cancel) {
                pendingConfirmation = nil
            }
        }
        .alert(
            lastFailure.map { "\($0.taskLabel) failed" } ?? "",
            isPresented: Binding(get: { lastFailure != nil }, set: { if !$0 { lastFailure = nil } })
        ) {
            Button("OK") { lastFailure = nil }
        } message: {
            if let lastFailure { Text(lastFailure.message) }
        }
        .alert("Done", isPresented: Binding(
            get: { successAlertMessage != nil },
            set: { if !$0 { successAlertMessage = nil } }
        )) {
            Button("OK") { successAlertMessage = nil }
        } message: {
            if let successAlertMessage {
                Text(successAlertMessage)
            }
        }
    }

    private var envMenu: some View {
        Menu {
            Button {
                onOpenEnv()
            } label: {
                Label("Edit .env", systemImage: "doc.text")
            }
            Divider()
            Button {
                showingShareEnv = true
            } label: {
                Label("Share on LAN…", systemImage: "wifi")
            }
            Button {
                showingReceiveEnv = true
            } label: {
                Label("Receive from LAN…", systemImage: "arrow.down.circle")
            }
        } label: {
            Label(".env", systemImage: "doc.text")
        } primaryAction: {
            onOpenEnv()
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.laradeckOutline)
        .fixedSize()
        .help("Edit .env (click) or share it (arrow)")
    }

    private var artisanMenu: some View {
        Menu {
            ForEach(artisanTasks) { task in
                Button {
                    trigger(task)
                } label: {
                    Label(task.label, systemImage: task.systemImage)
                }
            }
        } label: {
            HStack(spacing: 4) {
                if runningTask != nil {
                    ProgressView().controlSize(.small)
                }
                Text("Artisan")
            }
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.laradeckOutline)
        .disabled(runningTask != nil)
        .fixedSize()
        .help(runningTask.map { "Running \($0.label)…" } ?? "Artisan commands")
    }

    private func trigger(_ task: ArtisanTask) {
        if task.requiresConfirmation {
            pendingConfirmation = task
            showingMigrateConfirmation = true
        } else {
            Task { await runTask(task) }
        }
    }

    private func runTask(_ task: ArtisanTask) async {
        runningTask = task
        lastFailure = nil
        defer { runningTask = nil }

        let result = await ArtisanTaskService.run(task, project: project)

        if result.succeeded {
            successAlertMessage = task.successMessage
            if task == .storageLink || task == .migrate {
                insights = LaravelInsightsService.loadInstant(project: project)
                if task == .migrate {
                    insights.pendingMigrations = await LaravelInsightsService.loadMigrationStatus(project: project)
                        ?? insights.pendingMigrations
                }
                appState.storeLaravelInsights(insights, for: project.id)
                onTaskSucceeded()
            }
        } else {
            let reason = result.stderrSnippet ?? "Exit code \(result.exitCode)"
            lastFailure = ArtisanFailure(taskLabel: task.label, message: reason)
        }
    }
}
