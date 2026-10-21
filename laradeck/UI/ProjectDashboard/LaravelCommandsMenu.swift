import SwiftUI

/// Laravel artisan shortcuts and .env editor, shown as a header dropdown on the project dashboard.
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
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                Button {
                    onOpenEnv()
                } label: {
                    Label("Open .env", systemImage: "doc.text")
                }
                Button {
                    showingShareEnv = true
                } label: {
                    Label("Share .env on LAN…", systemImage: "wifi")
                }
                Button {
                    showingReceiveEnv = true
                } label: {
                    Label("Receive .env…", systemImage: "arrow.down.circle")
                }

                if !artisanTasks.isEmpty {
                    Divider()

                    ForEach(artisanTasks) { task in
                        Button {
                            trigger(task)
                        } label: {
                            Label(task.label, systemImage: task.systemImage)
                        }
                        .disabled(runningTask != nil)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    if runningTask != nil {
                        ProgressView().controlSize(.small)
                    }
                    Text("Commands")
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.laradeckOutline)
            .disabled(runningTask != nil)
            .fixedSize()

            if let lastFailure {
                failureBanner(lastFailure)
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

    private func trigger(_ task: ArtisanTask) {
        if task.requiresConfirmation {
            pendingConfirmation = task
            showingMigrateConfirmation = true
        } else {
            Task { await runTask(task) }
        }
    }

    private func failureBanner(_ failure: ArtisanFailure) -> some View {
        NoticeBanner(
            tone: .error,
            message: "\(failure.taskLabel) failed — \(failure.message)"
        ) {
            lastFailure = nil
        }
        .frame(maxWidth: 420, alignment: .leading)
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
