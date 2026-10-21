import DBEngineKit
import PhpSwitcherCore
import SwiftUI
import AppKit

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Binding var showingAddProject: Bool
    @State private var searchText = ""
    @State private var showingNewGroupPrompt = false
    @State private var newGroupName = ""
    @State private var pendingProjectForNewGroup: Project?
    @State private var renamingGroup: SidebarGroup?
    @State private var renameGroupText = ""
    @State private var showingNewDatabase = false
    @State private var showingNewService = false
    @AppStorage("sidebarServicesExpanded") private var servicesExpanded = true
    @AppStorage("sidebarDatabasesExpanded") private var databasesExpanded = true

    var body: some View {
        projectList
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search projects and databases")
        .navigationTitle("Laradeck")
        .toolbar {
            ToolbarItem {
                Menu {
                    Button {
                        showingAddProject = true
                    } label: {
                        Label("Add Project…", systemImage: "plus")
                    }
                    Button {
                        pendingProjectForNewGroup = nil
                        newGroupName = ""
                        showingNewGroupPrompt = true
                    } label: {
                        Label("New Group…", systemImage: "folder.badge.plus")
                    }
                    Divider()
                    Button {
                        showingNewDatabase = true
                    } label: {
                        Label("New Database…", systemImage: "cylinder.split.1x2")
                    }
                    Button {
                        showingNewService = true
                    } label: {
                        Label("New Service…", systemImage: "shippingbox")
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingNewDatabase) {
            NewDatabaseSheet()
        }
        .sheet(isPresented: $showingNewService) {
            GeneralServiceEditorSheet()
        }
        .alert("New Group", isPresented: $showingNewGroupPrompt) {
            TextField("Group name", text: $newGroupName)
            Button("Cancel", role: .cancel) {
                newGroupName = ""
                pendingProjectForNewGroup = nil
            }
            Button("Create") {
                createGroupFromPrompt()
            }
        }
        .alert("Rename Group", isPresented: renamingGroupBinding) {
            TextField("Group name", text: $renameGroupText)
            Button("Cancel", role: .cancel) { renamingGroup = nil }
            Button("Save") {
                commitRename()
            }
        }
    }

    /// Native sidebar list: system vibrancy and accent selection, arrow keys move the selection.
    private var projectList: some View {
        @Bindable var appState = appState

        return List(selection: selection) {
            if searchText.isEmpty || !filteredDatabases.isEmpty || !filteredDockerDatabases.isEmpty {
                Section(isExpanded: $databasesExpanded) {
                    ForEach(filteredDatabases) { row in
                        SidebarDatabaseRow(row: row)
                            .tag(SidebarItem.database(row.id))
                    }
                    if appState.databaseManager.rows.isEmpty && searchText.isEmpty {
                        SidebarAddRowPlaceholder(
                            systemImage: "cylinder.split.1x2",
                            title: "Add new database",
                            subtitle: "PostgreSQL, MySQL or Redis"
                        ) { showingNewDatabase = true }
                            .selectionDisabled()
                    }
                    ForEach(filteredDockerDatabases) { database in
                        SidebarDockerDatabaseRow(database: database)
                            .tag(SidebarItem.dockerDatabase(database.id))
                    }
                } header: {
                    SidebarDatabasesHeader()
                }
            }
            if searchText.isEmpty || !filteredServices.isEmpty || showsPhpRow || showsNodeRow {
                Section(isExpanded: $servicesExpanded) {
                    if showsPhpRow {
                        SidebarPhpRow()
                            .tag(SidebarItem.php)
                    }
                    if showsNodeRow {
                        SidebarNodeRow()
                            .tag(SidebarItem.node)
                    }
                    ForEach(filteredServices) { service in
                        SidebarGeneralServiceRow(service: service)
                            .tag(SidebarItem.service(service.id))
                    }
                    if appState.generalServices.services.isEmpty && searchText.isEmpty {
                        SidebarAddRowPlaceholder(
                            systemImage: "shippingbox",
                            title: "Add new service",
                            subtitle: "Mailpit, Gotenberg… from a compose YAML"
                        ) { showingNewService = true }
                        .selectionDisabled()
                    }
                } header: {
                    SidebarServicesHeader()
                }
            }
            if !favorites.isEmpty {
                Section("Favorites") {
                    reorderableRows(favorites)
                }
            }
            ForEach(visibleGroups) { group in
                Section(isExpanded: expandedBinding(for: group)) {
                    reorderableRows(projects(in: group))
                } header: {
                    SidebarGroupHeader(
                        group: group,
                        onRename: { beginRenaming(group) }
                    )
                }
            }
            if !ungroupedProjects.isEmpty {
                Section {
                    reorderableRows(ungroupedProjects)
                } header: {
                    SidebarUngroupedHeader(
                        title: appState.sidebarGroups.isEmpty ? "All Projects" : "Ungrouped"
                    )
                }
            }
        }
    }

    private func projectRow(for project: Project, isLastInSection: Bool = false) -> some View {
        ProjectRow(
            project: project,
            isLastInSection: isLastInSection,
            onMoveToNewGroup: { beginNewGroup(for: project) }
        )
        .tag(SidebarItem.project(project.id))
    }

    /// Renders a section's rows, each able to accept an insertion-line drop on its own top
    /// (and, for the last row, bottom) edge — no extra rows, so row height stays untouched.
    @ViewBuilder
    private func reorderableRows(_ sectionProjects: [Project]) -> some View {
        ForEach(sectionProjects) { project in
            projectRow(for: project, isLastInSection: project.id == sectionProjects.last?.id)
        }
    }

    /// One selection for every kind of row; maps onto AppState's per-kind selection.
    private var selection: Binding<SidebarItem?> {
        Binding(
            get: {
                if appState.showingPhp { return .php }
                if appState.showingNode { return .node }
                if let id = appState.selectedProjectId { return .project(id) }
                if let id = appState.selectedDatabaseId { return .database(id) }
                if let id = appState.selectedDockerDatabaseId { return .dockerDatabase(id) }
                if let id = appState.selectedServiceId { return .service(id) }
                return nil
            },
            set: { item in
                switch item {
                case .php: appState.showingPhp = true
                case .node: appState.showingNode = true
                case .project(let id): appState.selectedProjectId = id
                case .database(let id): appState.selectedDatabaseId = id
                case .dockerDatabase(let id): appState.selectedDockerDatabaseId = id
                case .service(let id): appState.selectedServiceId = id
                case nil:
                    appState.showingPhp = false
                    appState.showingNode = false
                    appState.selectedProjectId = nil
                    appState.selectedDatabaseId = nil
                    appState.selectedDockerDatabaseId = nil
                    appState.selectedServiceId = nil
                }
            }
        )
    }

    private var filteredDatabases: [DatabaseManager.Row] {
        let rows = appState.databaseManager.rows
        guard !searchText.isEmpty else { return rows }
        return rows.filter {
            $0.service.name.localizedCaseInsensitiveContains(searchText)
                || $0.service.kind.displayName.localizedCaseInsensitiveContains(searchText)
                || String($0.service.port).contains(searchText)
        }
    }

    /// Only running containers, plus the one open in the detail column (so stopping it there
    /// doesn't yank the page away).
    private var filteredDockerDatabases: [DockerDatabase] {
        let all = appState.dockerDatabases.filter {
            $0.isRunning || $0.id == appState.selectedDockerDatabaseId
        }
        guard !searchText.isEmpty else { return all }
        return all.filter {
            $0.service.localizedCaseInsensitiveContains(searchText)
                || $0.projectName.localizedCaseInsensitiveContains(searchText)
                || $0.kind.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var showsPhpRow: Bool {
        searchText.isEmpty || "php".localizedCaseInsensitiveContains(searchText)
            || searchText.localizedCaseInsensitiveContains("php")
    }

    private var showsNodeRow: Bool {
        guard appState.nodeManager.isNvmInstalled else { return false }
        return searchText.isEmpty || ["node", "nvm"].contains { $0.localizedCaseInsensitiveContains(searchText) }
            || searchText.localizedCaseInsensitiveContains("node")
    }

    private var filteredServices: [GeneralService] {
        let all = appState.generalServices.services
        guard !searchText.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || ($0.image ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    private var favorites: [Project] {
        appState.projects.filter(\.favorite)
    }

    private var filteredProjects: [Project] {
        guard !searchText.isEmpty else { return appState.projects }
        return appState.projects.filter { project in
            project.name.localizedCaseInsensitiveContains(searchText)
                || project.path.localizedCaseInsensitiveContains(searchText)
                || project.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    /// Groups are hidden while searching if none of their projects match.
    private var visibleGroups: [SidebarGroup] {
        guard !searchText.isEmpty else { return appState.sidebarGroups }
        return appState.sidebarGroups.filter { !projects(in: $0).isEmpty }
    }

    private func projects(in group: SidebarGroup) -> [Project] {
        filteredProjects.filter { $0.sidebarGroupId == group.id }
    }

    private var ungroupedProjects: [Project] {
        filteredProjects.filter { project in
            guard let groupId = project.sidebarGroupId else { return true }
            return !appState.sidebarGroups.contains { $0.id == groupId }
        }
    }

    private func expandedBinding(for group: SidebarGroup) -> Binding<Bool> {
        Binding(
            get: { group.isExpanded },
            set: { appState.setSidebarGroupExpanded(group, isExpanded: $0) }
        )
    }

    private var renamingGroupBinding: Binding<Bool> {
        Binding(
            get: { renamingGroup != nil },
            set: { if !$0 { renamingGroup = nil } }
        )
    }

    private func beginRenaming(_ group: SidebarGroup) {
        renameGroupText = group.name
        renamingGroup = group
    }

    private func beginNewGroup(for project: Project) {
        pendingProjectForNewGroup = project
        newGroupName = ""
        showingNewGroupPrompt = true
    }

    private func createGroupFromPrompt() {
        let trimmed = newGroupName.trimmingCharacters(in: .whitespaces)
        defer {
            newGroupName = ""
            pendingProjectForNewGroup = nil
        }
        guard !trimmed.isEmpty else { return }
        let group = appState.addSidebarGroup(name: trimmed)
        if let project = pendingProjectForNewGroup {
            appState.moveProject(project, toSidebarGroup: group.id)
        }
    }

    private func commitRename() {
        defer { renamingGroup = nil }
        guard let group = renamingGroup else { return }
        let trimmed = renameGroupText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        appState.renameSidebarGroup(group, to: trimmed)
    }
}

private struct SidebarGroupHeader: View {
    @Environment(AppState.self) private var appState
    let group: SidebarGroup
    let onRename: () -> Void

    var body: some View {
        Text(group.name)
            .contextMenu {
                Button("Rename Group…", action: onRename)
                Button("Move Up") {
                    appState.moveSidebarGroup(group, offset: -1)
                }
                .disabled(!canMoveUp)
                Button("Move Down") {
                    appState.moveSidebarGroup(group, offset: 1)
                }
                .disabled(!canMoveDown)
                Divider()
                Button("Delete Group", role: .destructive) {
                    appState.removeSidebarGroup(group)
                }
            }
            .draggable(SidebarGroupDragItem(groupId: group.id))
            .dropDestination(for: SidebarGroupDragItem.self) { items, _ in
                guard let dragged = items.first else { return false }
                appState.reorderSidebarGroup(dragged.groupId, toBefore: group.id)
                return true
            }
            .dropDestination(for: SidebarProjectDragItem.self) { items, _ in
                guard let dragged = items.first,
                      let project = appState.project(withId: dragged.projectId) else { return false }
                appState.moveProject(project, toSidebarGroup: group.id)
                return true
            }
    }

    private var groupIndex: Int? {
        appState.sidebarGroups.firstIndex(where: { $0.id == group.id })
    }

    private var canMoveUp: Bool {
        guard let index = groupIndex else { return false }
        return index > 0
    }

    private var canMoveDown: Bool {
        guard let index = groupIndex else { return false }
        return index < appState.sidebarGroups.count - 1
    }
}

private struct SidebarUngroupedHeader: View {
    @Environment(AppState.self) private var appState
    let title: String

    var body: some View {
        Text(title)
            .dropDestination(for: SidebarProjectDragItem.self) { items, _ in
                guard let dragged = items.first,
                      let project = appState.project(withId: dragged.projectId) else { return false }
                appState.moveProject(project, toSidebarGroup: nil)
                return true
            }
    }
}

private struct ProjectRow: View {
    @Environment(AppState.self) private var appState
    let project: Project
    var isLastInSection: Bool = false
    let onMoveToNewGroup: () -> Void
    @State private var showingEditSheet = false
    @State private var isDropTargetedBefore = false

    var body: some View {
        HStack {
            ProjectFaviconView(project: project, size: 28)
            StatusDotView(color: appState.health(for: project).color, size: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                Text(project.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(project.path)
            }
            Spacer()
            if LaravelDetector.isLaravelProject(at: project.path) {
                LaravelLogoView(size: 30)
                    .help(project.environment == .sail ? "Laravel Sail" : "Laravel")
            }
        }
        .contextMenu {
            Button("Edit Project…") {
                showingEditSheet = true
            }
            Button(project.favorite ? "Remove from Favorites" : "Add to Favorites") {
                appState.toggleFavorite(project)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([project.directoryURL])
            }
            Menu("Move to Group") {
                ForEach(appState.sidebarGroups) { group in
                    Button {
                        appState.moveProject(project, toSidebarGroup: group.id)
                    } label: {
                        if project.sidebarGroupId == group.id {
                            Label(group.name, systemImage: "checkmark")
                        } else {
                            Text(group.name)
                        }
                    }
                }
                if !appState.sidebarGroups.isEmpty {
                    Divider()
                }
                Button("New Group…", action: onMoveToNewGroup)
                if project.sidebarGroupId != nil {
                    Divider()
                    Button("Remove from Group") {
                        appState.moveProject(project, toSidebarGroup: nil)
                    }
                }
            }
            Divider()
            Button("Remove Project", role: .destructive) {
                appState.removeProject(project)
            }
        }
        .sheet(isPresented: $showingEditSheet) {
            EditProjectView(project: project)
        }
        .draggable(SidebarProjectDragItem(projectId: project.id))
        .overlay(alignment: .top) {
            if isDropTargetedBefore {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
        }
        .dropDestination(for: SidebarProjectDragItem.self) { items, _ in
            guard let dragged = items.first, dragged.projectId != project.id else { return false }
            appState.reorderProject(dragged.projectId, toBefore: project.id)
            return true
        } isTargeted: { targeted in
            isDropTargetedBefore = targeted
        }
        .overlay(alignment: .bottom) {
            if isLastInSection {
                SidebarAfterLastDropStrip(project: project)
            }
        }
    }
}

/// A thin, invisible-until-hovered strip pinned to the last row's bottom edge — lets a drag
/// land "after everything" without adding a row of its own (which would inflate list spacing).
private struct SidebarAfterLastDropStrip: View {
    @Environment(AppState.self) private var appState
    let project: Project

    @State private var isTargeted = false

    var body: some View {
        ZStack {
            if isTargeted {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
        }
        .frame(height: 8)
        .contentShape(Rectangle())
        .dropDestination(for: SidebarProjectDragItem.self) { items, _ in
            guard let dragged = items.first, dragged.projectId != project.id else { return false }
            appState.reorderProject(dragged.projectId, toAfter: project.id)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }
}

/// "Databases" section header: click the title for the overview.
private struct SidebarDatabasesHeader: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 6) {
            Button {
                appState.showingDatabases = true
            } label: {
                HStack(spacing: 4) {
                    Text("Databases")
                    let running = appState.databaseManager.runningCount
                    if running > 0 {
                        Text("\(running) running")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Show all databases")
            Spacer()
        }
    }
}

private struct SidebarDatabaseRow: View {
    @Environment(AppState.self) private var appState
    let row: DatabaseManager.Row
    @State private var confirmingDelete = false

    private var isBusy: Bool { appState.databaseManager.busy.contains(row.id) }

    var body: some View {
        HStack {
            // No ProgressView here: inside the sidebar's accent-tinted List an AppKit spinner
            // resolves the tint recursively and overflows the stack. Pulse the dot instead.
            Image(systemName: "cylinder.split.1x2.fill")
                .font(.system(size: 17))
                .foregroundStyle(row.service.kind.tint)
                .frame(width: 28, height: 28)
            StatusDotView(color: isBusy ? .yellow : row.status.color, size: 8, pulsing: isBusy)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.service.name)
                Text(verbatim: ":\(row.service.port) · \(row.service.kind.displayName) \(row.service.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if row.service.isShared {
                Image(systemName: "network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Shared on the local network")
            }
        }
        .contextMenu {
            DatabaseMenuItems(row: row) { confirmingDelete = true }
        }
        .databaseDeleteConfirmation(row.service, isPresented: $confirmingDelete) {
            if appState.selectedDatabaseId == row.id { appState.selectedDatabaseId = nil }
            appState.databaseManager.delete(row.service)
        }
    }
}

/// Shown in an empty section: looks like a regular row, in gray, and adds one when clicked.
private struct SidebarAddRowPlaceholder: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let onCreate: () -> Void

    var body: some View {
        Button(action: onCreate) {
            HStack {
                Image(systemName: systemImage)
                    .font(.system(size: 17))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 28)
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.secondary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

/// A database container in a project's Compose / Sail stack. Clicking opens the project.
private struct SidebarDockerDatabaseRow: View {
    @Environment(AppState.self) private var appState
    let database: DockerDatabase

    var body: some View {
        HStack {
            Image(systemName: "cylinder.split.1x2.fill")
                .font(.system(size: 17))
                .foregroundStyle(database.kind.tint)
                .frame(width: 28, height: 28)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                        .padding(2.5)
                        .background(Circle().fill(Color(red: 0.11, green: 0.51, blue: 0.93)))
                        .offset(x: 2, y: 2)
                }
            StatusDotView(color: database.isRunning ? .green : .gray, size: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(database.service)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .help("\(database.kind.displayName) in Docker · \(database.projectName)")
        .contextMenu {
            Button(database.isRunning ? "Stop Container" : "Start Container") {
                appState.toggleDockerDatabase(database)
            }
            .disabled(!appState.dockerManager.isDaemonRunning)
            Divider()
            if DatabaseManager.hasTablePlus {
                Button("Open in TablePlus") { appState.openDockerDatabaseInTablePlus(database) }
                    .disabled(database.hostPort == nil || !database.isRunning)
            }
            Button("Open Shell in Container") {
                TerminalLauncher.openContainerShell(appState.preferredTerminal,
                                                    projectPath: database.projectPath,
                                                    service: database.service)
            }
            .disabled(!database.isRunning)
            Divider()
            Button("Show \(database.projectName)") { appState.selectedProjectId = database.projectId }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let port = database.hostPort { parts.append(":\(port)") }
        parts.append("Docker")
        parts.append(database.projectName)
        return parts.joined(separator: " · ")
    }
}

private struct SidebarServicesHeader: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 4) {
            Text("Services")
            let running = appState.generalServices.runningCount
            if running > 0 {
                Text("\(running) running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .help("Docker Compose services shared by all projects — drop a .yaml on the window to add one")
    }
}

private struct SidebarGeneralServiceRow: View {
    @Environment(AppState.self) private var appState
    let service: GeneralService
    @State private var showingEditor = false
    @State private var confirmingDelete = false

    private var services: GeneralServicesManager { appState.generalServices }

    var body: some View {
        let isRunning = services.isRunning(service)
        let isBusy = services.busy.contains(service.id)
        let ports = Array(Set(services.containers(service).flatMap(\.ports))).sorted()
        HStack {
            // Pulsing dot instead of a ProgressView: an AppKit spinner in this tinted List overflows the stack.
            Image(systemName: service.systemImage)
                .font(.system(size: 16))
                .foregroundStyle(GeneralService.tint)
                .frame(width: 28, height: 28)
            StatusDotView(color: isBusy ? .yellow : (isRunning ? .green : .gray), size: 8, pulsing: isBusy)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.displayName)
                Text(ports.isEmpty ? (isRunning ? "Running" : "Stopped") : ports.map { ":\($0)" }.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .contextMenu {
            GeneralServiceMenuItems(service: service,
                                    onEdit: { showingEditor = true },
                                    onDelete: { confirmingDelete = true })
        }
        .sheet(isPresented: $showingEditor) {
            GeneralServiceEditorSheet(editing: service)
        }
        .generalServiceDeleteConfirmation(service, isPresented: $confirmingDelete) { removeVolumes in
            if appState.selectedServiceId == service.id { appState.selectedServiceId = nil }
            services.delete(service, removeVolumes: removeVolumes)
        }
    }
}

/// Anything selectable in the sidebar.
enum SidebarItem: Hashable {
    case php
    case node
    case project(UUID)
    case database(UUID)
    case dockerDatabase(String)
    case service(UUID)
}

/// The Homebrew PHP row at the top of Services: linked version, opens the PHP page.
private struct SidebarPhpRow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let php = appState.phpManager
        let isBusy = php.busy != nil
        HStack {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.indigo)
                .frame(width: 28, height: 28)
            StatusDotView(color: isBusy ? .yellow : (php.active != nil ? .green : .gray), size: 8, pulsing: isBusy)
            VStack(alignment: .leading, spacing: 2) {
                Text(php.active.map { "Php \($0.version.short)" } ?? "Php")
                Text(subtitle(php))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .contextMenu {
            ForEach(php.installed) { installation in
                Button {
                    appState.switchPhpShowingProgress(to: installation)
                } label: {
                    if php.isActive(installation) {
                        Label("PHP \(installation.version.short)", systemImage: "checkmark")
                    } else {
                        Text("Switch to PHP \(installation.version.short)")
                    }
                }
                .disabled(php.isActive(installation) || php.busy != nil)
            }
        }
    }

    private func subtitle(_ php: PhpManager) -> String {
        if let busy = php.busy { return busy }
        var parts = ["Homebrew"]
        if php.installed.count > 1 { parts.append("\(php.installed.count) versions") }
        if php.usesValet { parts.append("Valet") }
        return parts.joined(separator: " · ")
    }
}

/// The nvm row under PHP in Services: default Node version, opens the Node page.
private struct SidebarNodeRow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let node = appState.nodeManager
        let isBusy = node.busy != nil
        HStack {
            Image(systemName: "hexagon")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 28, height: 28)
            StatusDotView(color: isBusy ? .yellow : (node.defaultInstallation != nil ? .green : .gray), size: 8, pulsing: isBusy)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.defaultInstallation.map { "Node \($0.version.major)" } ?? "Node")
                Text(subtitle(node))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .contextMenu {
            ForEach(node.installed) { installation in
                Button {
                    Task { await node.setDefault(installation) }
                } label: {
                    if node.isDefault(installation) {
                        Label("Node \(installation.version.description)", systemImage: "checkmark")
                    } else {
                        Text("Make Node \(installation.version.description) the default")
                    }
                }
                .disabled(node.isDefault(installation) || node.busy != nil)
            }
        }
    }

    private func subtitle(_ node: NodeManager) -> String {
        if let busy = node.busy { return busy }
        var parts = ["nvm"]
        if let version = node.defaultInstallation?.version { parts.append(version.description) }
        if node.installed.count > 1 { parts.append("\(node.installed.count) versions") }
        return parts.joined(separator: " · ")
    }
}
