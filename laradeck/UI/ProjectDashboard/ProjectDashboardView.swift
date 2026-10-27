import SwiftUI
import AppKit
import PhpSwitcherCore

struct ProjectDashboardView: View {
    private enum Screen {
        case dashboard
        case envEditor
        case logs
        case dumps
    }

    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    let project: Project

    private struct GroupSection: Identifiable {
        let id: ProcessDestination
        let name: String
        let processes: [ProcessDefinition]

        var isDeletable: Bool {
            if case .group = id {
                return name != ScriptCommandDiscovery.otherCommandsGroupName
            }
            return false
        }
    }

    @State private var screen: Screen = .dashboard
    @State private var customProcessDestination: ProcessDestination?
    @State private var groupPendingRemoval: ProcessGroup?
    @State private var showingStopAllConfirmation = false
    @State private var showingEditProject = false
    @State private var showingRefreshCommands = false
    @State private var logsInitialSource = LogManager.laravelSource
    @State private var laravelInsightsRefreshToken = 0
    @State private var gitBranch: String?
    @State private var showingProjectInfo = false
    @State private var databaseRequirements: [ProjectDatabaseRequirement] = []
    /// Start All was pressed while the linked PHP doesn't fit composer.json.
    @State private var phpMismatchOnStart: ProjectPhpMismatch?

    private var groupSections: [GroupSection] {
        var sections: [GroupSection] = [
            GroupSection(
                id: .preStart,
                name: "Pre-start",
                processes: project.processes.filter { $0.effectiveRole == .preStart }
            ),
            GroupSection(
                id: .processes,
                name: "Processes",
                processes: project.processes.filter { $0.effectiveRole == .normal && $0.groupId == nil }
            ),
        ]
        for group in project.effectiveProcessGroups {
            sections.append(
                GroupSection(
                    id: .group(group.id),
                    name: group.name,
                    processes: project.processes.filter { $0.effectiveRole == .normal && $0.groupId == group.id }
                )
            )
        }
        sections.append(
            GroupSection(
                id: .postStart,
                name: "Post-start",
                processes: project.processes.filter { $0.effectiveRole == .postStart }
            )
        )
        sections.append(
            GroupSection(
                id: .postStop,
                name: "Post-stop",
                processes: project.processes.filter { $0.effectiveRole == .postStop }
            )
        )
        return sections
    }

    var body: some View {
        screenView
            .onAppear(perform: consumePendingDumpsOpen)
            .onChange(of: appState.pendingDumpsOpen) { consumePendingDumpsOpen() }
    }

    @ViewBuilder
    private var screenView: some View {
        switch screen {
        case .dashboard:
            dashboardView
        case .envEditor:
            EnvEditorView(project: project) { screen = .dashboard }
        case .logs:
            LogsView(project: project, initialSource: logsInitialSource) { screen = .dashboard }
        case .dumps:
            DumpsView(target: dumpTarget) { screen = .dashboard }
        }
    }

    private var dumpTarget: DumpTarget { .project(project.id) }

    /// Inline, or brings the detached window forward when the stream lives in its own window.
    private func openDumps() {
        if appState.dumpService.isDetached(dumpTarget) {
            DumpsWindow.open(dumpTarget, service: appState.dumpService, openWindow: openWindow)
        } else {
            screen = .dumps
        }
    }

    private func consumePendingDumpsOpen() {
        guard appState.pendingDumpsOpen == project.id else { return }
        appState.pendingDumpsOpen = nil
        screen = .dumps
    }

    private func openLogs(for sourceName: String) {
        logsInitialSource = sourceName
        screen = .logs
    }

    private var isLaravelProject: Bool {
        LaravelDetector.isLaravelProject(at: project.path)
    }

    private var dashboardView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    ProjectPhpBanner(project: project)
                    ProjectNodeBanner(project: project)

                    if !databaseRequirements.isEmpty {
                        ProjectDatabasesView(project: project, requirements: databaseRequirements)
                    }

                    if project.hasDockerCompose {
                        SailServicesView(project: project, onOpenLogs: openLogs)
                    }

                    ProjectDumpsSummary(project: project, onOpen: openDumps)

                    processSection
                }
                .padding(20)
            }
        }
        .background(LaradeckTheme.pageBackground)
        .task(id: laravelInsightsRefreshToken) {
            databaseRequirements = ProjectDatabaseLink.requirements(for: project)
            if isLaravelProject {
                await LaravelInsightsLoader.refresh(project: project, appState: appState)
            }
        }
        .laradeckTitle(project.name)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    appState.selectedProjectId = nil
                } label: {
                    Label("Close", systemImage: "xmark")
                }
                .help("Close project")
            }
            ToolbarItem {
                Menu {
                    Button {
                        showingEditProject = true
                    } label: {
                        Label("Edit Project…", systemImage: "pencil")
                    }
                    Button {
                        showingRefreshCommands = true
                    } label: {
                        Label("Refresh Commands…", systemImage: "arrow.triangle.2.circlepath")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("Edit project, refresh commands")
            }
        }
        .confirmationDialog(
            "\(project.name) requires PHP \(phpMismatchOnStart?.constraint ?? "")",
            isPresented: Binding(get: { phpMismatchOnStart != nil }, set: { if !$0 { phpMismatchOnStart = nil } }),
            presenting: phpMismatchOnStart
        ) { mismatch in
            if let target = mismatch.suggestion {
                Button("Switch to PHP \(target.version.short) and Start") {
                    Task {
                        if await appState.phpManager.switchTo(target) {
                            appState.phpManager.pendingProcessRestart = false
                        }
                        appState.startAll(project)
                    }
                }
            }
            Button("Start with PHP \(mismatch.active)") { appState.startAll(project) }
            Button("Cancel", role: .cancel) {}
        } message: { mismatch in
            Text("PHP \(mismatch.active) is linked in Homebrew.")
        }
        .confirmationDialog(
            "Stop all processes for \(project.name)?",
            isPresented: $showingStopAllConfirmation
        ) {
            Button("Stop All", role: .destructive) { appState.stopAll(project) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingEditProject) {
            EditProjectView(project: project)
        }
        .sheet(isPresented: $showingRefreshCommands) {
            RefreshCommandsSheet(project: project)
        }
    }

    /// Primary action, top right of the header (filled accent button, like Apple's "Start").
    @ViewBuilder
    private var startStopButton: some View {
        if hasRunningStartAllProcesses {
            Button {
                if appState.confirmBeforeStopAll {
                    showingStopAllConfirmation = true
                } else {
                    appState.stopAll(project)
                }
            } label: {
                Label("Stop All", systemImage: "stop.fill")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.bordered)
            .foregroundStyle(.red)
            .controlSize(.large)
        } else {
            Button {
                if let mismatch = appState.phpManager.mismatch(for: project) {
                    phpMismatchOnStart = mismatch
                } else {
                    appState.startAll(project)
                }
            } label: {
                Label("Start All", systemImage: "play.fill")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(project.hasDockerCompose && !appState.canStartProcesses(for: project))
            .help(startAllHelp + " (⌘R)")
        }
    }

    /// Three bands: who the project is (name, environment, branch, Start/Stop), where it lives
    /// (path, URL) and what it runs on (Laravel, PHP, Node, APP_ENV); then one action bar.
    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                ProjectFaviconView(project: project, size: 56)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(project.name)
                            .font(.largeTitle.bold())
                            .lineLimit(1)
                        environmentBadge
                        if let gitBranch {
                            GitBranchBadge(branch: gitBranch)
                        }
                    }
                    locationRow
                    versionsRow
                }

                Spacer(minLength: 12)

                startStopButton
            }

            actionBar
        }
        .task(id: project.path) {
            gitBranch = await GitRepositoryService.currentBranch(at: project.path)
        }
    }

    /// Path (opens Finder) and app URL (opens the browser).
    private var locationRow: some View {
        HStack(spacing: 8) {
            PathLinkButton(path: (project.path as NSString).abbreviatingWithTildeInPath, lineLimit: 1)
            if let url = project.effectiveURL {
                Text("·").foregroundStyle(.tertiary)
                LinkLabel(url: url, title: displayHost(url))
                    .font(.subheadline)
                    .help(url.absoluteString)
            }
        }
    }

    /// Laravel, PHP and Node versions (Node is a menu to pin a version).
    private var versionsRow: some View {
        HStack(spacing: 14) {
            if let laravelVersion = project.laravelVersion {
                HStack(spacing: 5) {
                    LaravelLogoView(size: 14)
                    Text("Laravel \(laravelVersion)")
                }
            }
            if let phpVersion = project.phpVersion {
                Label("PHP \(phpVersion)", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            ProjectNodeMenu(project: project)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    /// Open-in apps on the left; project tools (Logs, Dumps, .env, Artisan) on the right.
    private var actionBar: some View {
        HStack(spacing: 8) {
            if let url = project.effectiveURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Browser", systemImage: "globe")
                }
                .help("Open \(url.absoluteString)")
            }
            Button {
                NSWorkspace.shared.open(project.directoryURL)
            } label: {
                Label("Finder", systemImage: "folder")
            }
            .help("Open the project folder")
            Button {
                openTerminal()
            } label: {
                Label("Terminal", systemImage: "apple.terminal")
            }
            .help("Open \(appState.preferredTerminal.displayName) here")

            Divider().frame(height: 18).padding(.horizontal, 4)

            Button {
                openLogs(for: LogManager.laravelSource)
            } label: {
                Label("Logs", systemImage: "text.alignleft")
            }
            Button {
                openDumps()
            } label: {
                DumpsButtonLabel(unread: appState.dumpService.unreadCount(for: dumpTarget))
            }
            Button {
                showingProjectInfo.toggle()
            } label: {
                Label {
                    HStack(spacing: 5) {
                        Text("Info")
                        if infoNeedsAttention {
                            Circle().fill(.orange).frame(width: 7, height: 7)
                        }
                    }
                } icon: {
                    Image(systemName: "info.circle")
                }
            }
            .help(infoNeedsAttention ? "Pending migrations or storage link to fix" : "Environment and Laravel configuration")
            .popover(isPresented: $showingProjectInfo, arrowEdge: .bottom) {
                ProjectInfoPopover(
                    project: project,
                    environmentName: environmentName,
                    gitBranch: gitBranch,
                    isLaravel: isLaravelProject
                )
            }

            Spacer(minLength: 12)

            if isLaravelProject {
                LaravelCommandsMenu(project: project, onOpenEnv: { screen = .envEditor }) {
                    laravelInsightsRefreshToken += 1
                }
            } else {
                Button {
                    screen = .envEditor
                } label: {
                    Label(".env", systemImage: "doc.text")
                }
            }
        }
        .buttonStyle(.laradeckOutline)
        .padding(.top, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(LaradeckTheme.cardBorder).frame(height: 1)
        }
    }

    private var infoNeedsAttention: Bool {
        isLaravelProject && appState.cachedLaravelInsights(for: project.id)?.needsAttention == true
    }

    private func displayHost(_ url: URL) -> String {
        guard let host = url.host() else { return url.absoluteString }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    private var environmentBadge: some View {
        HeaderBadge(title: environmentName,
                    systemImage: project.hasDockerCompose ? "shippingbox" : "terminal")
    }

    private var environmentName: String {
        if project.environment == .sail { return "Sail" }
        return project.hasDockerCompose ? "Compose" : "Native"
    }

    private var startAllHelp: String {
        if project.hasDockerCompose, !appState.canStartProcesses(for: project) {
            return DockerManager.daemonUnavailableMessage
        }
        return "Start All"
    }

    /// True when Stop All should show: something is running, or a failed (red) badge still needs clearing.
    private var hasRunningStartAllProcesses: Bool {
        project.processes.contains { definition in
            guard project.isIncludedInStopAll(definition) else { return false }
            switch appState.processManager.status(for: definition.id) {
            case .running, .starting, .stopping, .failed:
                return true
            case .stopped:
                return false
            }
        }
    }

    /// Hide empty lifecycle sections; always keep Processes and named groups (e.g. Other commands).
    private var visibleGroupSections: [GroupSection] {
        groupSections.filter { section in
            switch section.id {
            case .processes, .group:
                return true
            case .preStart, .postStart, .postStop:
                return !section.processes.isEmpty
            }
        }
    }

    /// Processes and every named group (built-in "Other commands" included) get the same
    /// drag/reorder/attach sequence UI — only the lifecycle hook sections stay a plain list.
    private func sectionUsesSequenceList(_ section: GroupSection) -> Bool {
        switch section.id {
        case .processes, .group:
            return true
        case .preStart, .postStart, .postStop:
            return false
        }
    }

    private func sectionDragScope(_ section: GroupSection) -> String {
        switch section.id {
        case .processes: return "processes"
        case .preStart: return "preStart"
        case .postStart: return "postStart"
        case .postStop: return "postStop"
        case .group(let id): return "group:\(id.uuidString)"
        }
    }

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(visibleGroupSections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(section.name).font(.headline)
                        Spacer()
                        if section.isDeletable, let groupId = section.id.groupId,
                           let group = project.effectiveProcessGroups.first(where: { $0.id == groupId }) {
                            Button {
                                toggleIncludedInStartAll(group)
                            } label: {
                                Image(systemName: group.excludedFromStartAll ? "bolt.slash" : "bolt.fill")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(group.excludedFromStartAll ? Color.secondary : Color.accentColor)
                            .help(
                                group.excludedFromStartAll
                                    ? "Excluded from Start All — click to include"
                                    : "Included in Start All — click to exclude"
                            )
                            Button(role: .destructive) {
                                groupPendingRemoval = group
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Remove Group")
                        }
                        if section.id == .processes {
                            Button {
                                appendPause()
                            } label: {
                                Label("Add Pause", systemImage: "clock")
                            }
                            .buttonStyle(.laradeckOutline)
                        }
                        Button {
                            customProcessDestination = section.id
                        } label: {
                            Label("Add Custom Process", systemImage: "plus")
                        }
                        .buttonStyle(.laradeckOutline)
                    }
                    ProcessListView(
                        project: project,
                        processes: section.id == .processes
                            ? project.sortedByStartOrder(section.processes)
                            : section.processes,
                        isStartOrderList: sectionUsesSequenceList(section),
                        sequenceFilterIds: sectionUsesSequenceList(section)
                            ? Set(section.processes.map(\.id))
                            : nil,
                        includeRootDelays: section.id == .processes,
                        allowsSequencePauses: section.id == .processes,
                        allowsReorder: sectionUsesSequenceList(section),
                        dragScope: sectionDragScope(section),
                        onOpenLogs: openLogs
                    )
                }
            }
        }
        .sheet(item: $customProcessDestination) { destination in
            CustomProcessSheet(project: project, initialDestination: destination)
        }
        .confirmationDialog(
            "Remove group \"\(groupPendingRemoval?.name ?? "")\"? Its processes move back to \"Processes\".",
            isPresented: Binding(
                get: { groupPendingRemoval != nil },
                set: { isPresented in if !isPresented { groupPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Group", role: .destructive) { removeGroup() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func toggleIncludedInStartAll(_ group: ProcessGroup) {
        var updated = project
        var groups = updated.effectiveProcessGroups
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].excludedFromStartAll.toggle()
        updated.processGroups = groups
        appState.updateProject(updated)
    }

    private func removeGroup() {
        guard let group = groupPendingRemoval else { return }
        var updated = project
        updated.processGroups = project.effectiveProcessGroups.filter { $0.id != group.id }
        for index in updated.processes.indices where updated.processes[index].groupId == group.id {
            updated.processes[index].groupId = nil
        }
        appState.updateProject(updated)
        groupPendingRemoval = nil
    }

    private func appendPause() {
        var updated = project
        var sequence = updated.effectiveStartupSequence
        StartupSequence.appendPause(to: &sequence)
        updated.startupSequence = sequence
        appState.updateProject(updated)
    }

    private func openTerminal() {
        TerminalLauncher.open(appState.preferredTerminal, at: project.path)
    }
}
