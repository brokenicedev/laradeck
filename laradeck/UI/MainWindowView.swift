import DBEngineKit
import SwiftUI
import AppKit

struct MainWindowView: View {
    @Environment(AppState.self) private var appState
    @State private var showingAddProject = false
    @State private var addProjectInitialPath: String?
    @State private var wizardPath: String?
    @State private var isDropTargeted = false
    @State private var profileImportNotice: String?
    @State private var serviceImportError: String?

    var body: some View {
        @Bindable var appState = appState

        NavigationSplitView {
            SidebarView(showingAddProject: $showingAddProject)
                .scrollContentBackground(.hidden)
                .background(LaradeckTheme.current.header)
                .themedToolbar()
        } detail: {
            detailColumn
                .themedToolbar()
        }
        .toolbar {
            // Docker / PHP / Laravel installer status, centered like Xcode's activity view.
            ToolbarItem(placement: .status) {
                EnvironmentStatusView()
            }
        }
        .onAppear { appState.activateDumps() }
        .sheet(isPresented: $showingAddProject) {
            AddProjectView(initialPath: addProjectInitialPath)
        }
        .onChange(of: appState.pendingAddProjectRequest) { _, requested in
            guard requested else { return }
            addProjectInitialPath = nil
            showingAddProject = true
            appState.pendingAddProjectRequest = false
        }
        .sheet(item: wizardTargetBinding) { target in
            ProjectWizardView(path: target.path) {
                wizardPath = nil
            }
        }
        .sheet(item: Binding(
            get: { appState.pendingPortConflict },
            set: { appState.pendingPortConflict = $0 }
        )) { pending in
            PortConflictSheet(
                report: pending.report,
                intent: pending.intent,
                onCancel: { appState.dismissPortConflict() },
                onContinue: { appState.proceedDespitePortConflict() }
            )
        }
        .sheet(item: envReceiveActionBinding) { payload in
            EnvReceiveActionSheet(payload: payload)
        }
        .onReceive(NotificationCenter.default.publisher(for: .laradeckCheckForUpdates)) { _ in
            Task { @MainActor in
                await appState.versionCheck.checkForUpdates(userInitiated: true)
#if SPARKLE
                SparkleUpdaterController.shared.checkForUpdates()
#endif
            }
        }
        .alert(
            databasePromptTitle,
            isPresented: Binding(
                get: { appState.pendingDatabaseStart != nil },
                set: { if !$0 { appState.resolveDatabasePrompt(nil) } }
            ),
            presenting: appState.pendingDatabaseStart
        ) { _ in
            Button("Start Databases") { appState.resolveDatabasePrompt(.start) }
                .keyboardShortcut(.defaultAction)
            Button("Continue Without") { appState.resolveDatabasePrompt(.skip) }
            Button("Cancel", role: .cancel) { appState.resolveDatabasePrompt(nil) }
        } message: { pending in
            Text(databasePromptMessage(pending))
        }
        .alert("Couldn't Add Service", isPresented: Binding(
            get: { serviceImportError != nil },
            set: { if !$0 { serviceImportError = nil } }
        )) {
            Button("OK") { serviceImportError = nil }
        } message: {
            Text(serviceImportError ?? "")
        }
        .alert("Team config", isPresented: Binding(
            get: { profileImportNotice != nil },
            set: { if !$0 { profileImportNotice = nil } }
        )) {
            Button("OK") { profileImportNotice = nil }
        } message: {
            if let profileImportNotice {
                Text(profileImportNotice)
            }
        }
    }

    private var detailColumn: some View {
        Group {
            if let pending = appState.pendingEnvReceive, pending.phase == .mergeEditor {
                EnvReceiveReviewView(payload: pending) {
                    appState.pendingEnvReceive = nil
                }
                .id(pending.id)
            } else if appState.showingPhp {
                PhpView()
            } else if appState.showingNode {
                NodeView()
            } else if appState.showingDatabases {
                DatabasesView()
            } else if let id = appState.selectedDatabaseId, let row = appState.databaseManager.row(id: id) {
                DatabaseDetailView(row: row)
                    .id(id)
            } else if let id = appState.selectedServiceId, let service = appState.generalServices.service(id: id) {
                GeneralServiceDetailView(service: service)
                    .id(id)
            } else if let id = appState.selectedDockerDatabaseId,
                      let database = appState.dockerDatabases.first(where: { $0.id == id }) {
                DockerDatabaseDetailView(database: database)
                    .id(id)
            } else if let project = appState.selectedProject {
                ProjectDashboardView(project: project)
                    .id(project.id)
            } else {
                emptyDetailView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { ThemeBackground() }
        .safeAreaInset(edge: .top, spacing: 0) {
            if appState.pendingEnvReceive?.phase != .mergeEditor, let update = appState.versionCheck.bannerUpdate {
                UpdateAvailableBanner(
                    info: update,
                    onUpdate: { appState.versionCheck.openUpdate() },
                    onLater: { appState.versionCheck.dismissBanner() },
                    onSkip: { appState.versionCheck.skipThisVersion() }
                )
            }
        }
        .dropDestination(for: URL.self) { items, _ in
            guard !InAppSequenceDrag.isActive else { return false }
            handleDrop(items)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted && !InAppSequenceDrag.isActive
        }
        .overlay {
            if isDropTargeted {
                dropOverlay
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
        .animation(.easeInOut(duration: 0.2), value: appState.versionCheck.bannerUpdate?.build)
        .animation(.easeInOut(duration: 0.2), value: appState.pendingEnvReceive?.id)
    }

    /// Save / Overwrite / Merge chooser — only while still in `.chooseAction`.
    private var envReceiveActionBinding: Binding<IncomingEnvPayload?> {
        Binding(
            get: {
                guard let pending = appState.pendingEnvReceive,
                      pending.phase == .chooseAction else { return nil }
                return pending
            },
            set: { newValue in
                // Sheet dismissed: clear only if the user cancelled (still choosing).
                if newValue == nil, appState.pendingEnvReceive?.phase == .chooseAction {
                    appState.pendingEnvReceive = nil
                }
            }
        )
    }

    private var emptyDetailView: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 28) {
                heroAppIcon

                VStack(spacing: 8) {
                    Text("Stop juggling terminals.")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Start shipping.")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)

                Text(emptyDetailSubtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: 400)

                HStack(spacing: 12) {
                    Button {
                        addProjectInitialPath = nil
                        showingAddProject = true
                    } label: {
                        Label("Add Project", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Label("or drag a folder here", systemImage: "folder.badge.plus")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 48)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(.quaternary)
                .padding(32)
        }
    }

    private var emptyDetailSubtitle: String {
        if appState.projects.isEmpty {
            return "Laradeck is your native macOS control panel for Laravel — processes, Docker Compose, logs and artisan tasks in one place."
        }
        return "Select a project from the sidebar, add a new one, or drop a Laravel folder anywhere in this window."
    }

    @ViewBuilder
    private var heroAppIcon: some View {
        if let icon = NSApplication.shared.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.1), radius: 16, y: 6)
        }
    }

    private var dropOverlay: some View {
        ZStack {
            Color.accentColor.opacity(0.07)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [10, 6]))
                .padding(32)

            VStack(spacing: 12) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 40))
                Text("Drop to add project")
                    .font(.title3.weight(.semibold))
            }
            .foregroundStyle(Color.accentColor)
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private var wizardTargetBinding: Binding<DropTarget?> {
        Binding(
            get: { wizardPath.map(DropTarget.init) },
            set: { wizardPath = $0?.path }
        )
    }

    private var databasePromptTitle: String {
        guard let pending = appState.pendingDatabaseStart else { return "" }
        let name = appState.project(withId: pending.projectId)?.name ?? "This project"
        return pending.services.count == 1
            ? "\(name) uses a database that isn't running"
            : "\(name) uses databases that aren't running"
    }

    private func databasePromptMessage(_ pending: PendingDatabaseStart) -> String {
        let list = pending.services
            .map { "• \($0.name) (\($0.kind.displayName), port \($0.port))" }
            .joined(separator: "\n")
        return list + "\n\nStart \(pending.services.count == 1 ? "it" : "them") before the project's processes?"
    }

    private func handleDrop(_ urls: [URL]) {
        guard !InAppSequenceDrag.isActive else { return }
        guard let url = urls.first else { return }

        let fileURL = url.standardizedFileURL
        guard fileURL.isFileURL else { return }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else { return }

        // A compose YAML becomes a general service (Services section in the sidebar).
        if !isDirectory.boolValue, ["yaml", "yml"].contains(fileURL.pathExtension.lowercased()) {
            Task {
                do {
                    let service = try await appState.generalServices.importFile(fileURL)
                    appState.selectedServiceId = service.id
                } catch {
                    serviceImportError = "\(fileURL.lastPathComponent): \(error.localizedDescription)"
                }
            }
            return
        }
        guard isDirectory.boolValue else { return }

        switch LaradeckProjectImporter.tryImport(at: fileURL.path, into: appState) {
        case .imported(let project):
            profileImportNotice = "Added “\(project.name)” from team config (.laradeck). Wizard skipped."
        case .alreadyAdded:
            profileImportNotice = "That folder is already in your project list."
            if let existing = appState.projects.first(where: { $0.path == fileURL.path }) {
                appState.selectedProjectId = existing.id
            }
        case .failed(let message):
            profileImportNotice = "Could not read .laradeck: \(message)"
            wizardPath = fileURL.path
        case .noProfile:
            wizardPath = fileURL.path
        }
    }
}

private struct DropTarget: Identifiable {
    let path: String
    var id: String { path }
}
