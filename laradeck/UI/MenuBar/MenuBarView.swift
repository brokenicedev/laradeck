import DBEngineKit
import PhpSwitcherCore
import SwiftUI
import AppKit

/// The menu bar panel — a dbngin-style floating window (see `.menuBarExtraStyle(.window)` on the
/// scene) rather than a native NSMenu, so rows can carry hover states and a pill button instead of
/// plain menu items. One row per project (not per process) — like a single dbngin service row —
/// with its Start/Stop pill driving that project's Start All / Stop All.
struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @State private var isRefreshing = false
    /// Filters projects and databases in the panel.
    @State private var query = ""

    private let rowHeight: CGFloat = 40
    private let maxListHeight: CGFloat = 420

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            FilterField(prompt: "Search projects and databases", text: $query, maxWidth: nil)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            Divider()
            let showsPhp = query.isEmpty || "php".matchesFilter(query) || query.lowercased().contains("php")
            let showsNode = appState.nodeManager.isNvmInstalled
                && (query.isEmpty || "node".matchesFilter(query) || "nvm".matchesFilter(query)
                    || query.lowercased().contains("node"))
            if showsPhp || showsNode {
                VStack(alignment: .leading, spacing: 0) {
                    MenuBarSectionHeader(title: showsPhp && showsNode ? "Runtimes" : (showsPhp ? "PHP" : "Node"))
                    if showsPhp { phpRow }
                    if showsNode { nodeRow }
                }
                Divider()
            }
            databaseList
            projectList
        }
        .frame(width: 320)
        // MenuBarExtra(.window) sizes from SwiftUI intrinsic height — ScrollView alone often reports
        // zero and leaves an empty panel on recent macOS versions.
        .fixedSize(horizontal: true, vertical: true)
        .background(.regularMaterial)
    }

    private var filteredProjects: [Project] {
        appState.projects.filter {
            $0.name.matchesFilter(query) || $0.path.matchesFilter(query)
                || $0.tags.contains { $0.matchesFilter(query) }
        }
    }

    private var filteredDatabases: [DatabaseManager.Row] {
        appState.databaseManager.rows.filter {
            $0.service.name.matchesFilter(query) || $0.service.kind.displayName.matchesFilter(query)
                || String($0.service.port).matchesFilter(query)
        }
    }

    @ViewBuilder
    private var projectList: some View {
        let projects = filteredProjects
        if appState.projects.isEmpty {
            emptyState
        } else if projects.isEmpty {
            Text("No projects match “\(query)”")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        } else {
            let listHeight = min(CGFloat(projects.count) * rowHeight + 12, maxListHeight)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(projects) { project in
                        MenuBarProjectRow(project: project)
                    }
                }
                .padding(.vertical, 6)
                // Inside the content, so the probe's enclosingScrollView is this list.
                .overlayScrollers()
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: listHeight)
        }
    }

    /// Linked Homebrew PHP with a quick version switch.
    private var phpRow: some View {
        let php = appState.phpManager
        return HStack(spacing: 10) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.indigo)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(php.active.map { "PHP \($0.version.description)" } ?? "PHP")
                    .font(.system(size: 12.5, weight: .medium))
                Text(php.busy ?? (php.active?.formula ?? "Not linked"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if php.busy != nil {
                ProgressView().controlSize(.small)
            } else {
                Menu("Switch") {
                    ForEach(php.installed) { installation in
                        Button {
                            appState.switchPhpShowingProgress(to: installation)
                        } label: {
                            if php.isActive(installation) {
                                Label("PHP \(installation.version.short)", systemImage: "checkmark")
                            } else {
                                Text("PHP \(installation.version.short)")
                            }
                        }
                        .disabled(php.isActive(installation))
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.system(size: 11, weight: .medium))
                .disabled(php.installed.isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    /// nvm default Node with a quick switch (`nvm alias default`).
    private var nodeRow: some View {
        let node = appState.nodeManager
        return HStack(spacing: 10) {
            Image(systemName: "hexagon")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.defaultInstallation.map { "Node \($0.version.description)" } ?? "Node")
                    .font(.system(size: 12.5, weight: .medium))
                Text(node.busy ?? (node.defaultInstallation != nil ? "nvm default" : "No nvm default"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if node.busy != nil {
                ProgressView().controlSize(.small)
            } else {
                Menu("Switch") {
                    ForEach(node.installed) { installation in
                        Button {
                            Task { await node.setDefault(installation) }
                        } label: {
                            if node.isDefault(installation) {
                                Label("Node \(installation.version.description)", systemImage: "checkmark")
                            } else {
                                Text("Node \(installation.version.description)")
                            }
                        }
                        .disabled(node.isDefault(installation))
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.system(size: 11, weight: .medium))
                .disabled(node.installed.isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    @ViewBuilder
    private var databaseList: some View {
        let rows = filteredDatabases
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                MenuBarSectionHeader(title: "Databases")
                ForEach(rows) { row in
                    MenuBarDatabaseRow(row: row)
                }
            }
            .padding(.bottom, 6)
            Divider()
            MenuBarSectionHeader(title: "Projects")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            Button {
                AboutPanel.show()
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .help("About Laradeck")

            Button {
                refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    .animation(isRefreshing ? .linear(duration: 0.7).repeatForever(autoreverses: false) : .default, value: isRefreshing)
            }
            .help("Refresh")

            Spacer()

            Button {
                requestAddProject()
            } label: {
                Image(systemName: "plus")
            }
            .help("Add Project")

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .help("Settings")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit Laradeck")
        }
        .buttonStyle(.plain)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image("LaradeckMarkTemplate")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
                .foregroundStyle(.tertiary)
            Text("No projects yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func refreshAll() {
        isRefreshing = true
        Task {
            if appState.hasDockerComposeProjects {
                await appState.dockerManager.refreshDaemonState()
            }
            for project in appState.projects where project.hasDockerCompose {
                await appState.dockerManager.refreshStatus(for: project)
            }
            isRefreshing = false
        }
    }

    private func requestAddProject() {
        appState.pendingAddProjectRequest = true
        openMainWindow(selecting: nil)
    }

    private func openMainWindow(selecting project: Project?) {
        if let project {
            appState.selectedProjectId = project.id
        }
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

private struct MenuBarProjectRow: View {
    @Environment(AppState.self) private var appState
    let project: Project

    @State private var isHovering = false

    /// The processes Start All / Stop All actually drive — matches `ProcessManager.startAll`.
    private var trackedDefinitions: [ProcessDefinition] {
        project.processes.filter { project.isIncludedInStartAll($0) }
    }

    private var statuses: [ProcessStatus] {
        trackedDefinitions.map { appState.processManager.status(for: $0.id) }
    }

    private var isBusy: Bool {
        statuses.contains(.starting) || statuses.contains(.stopping)
    }

    private var isRunning: Bool {
        !statuses.isEmpty && statuses.allSatisfy { $0 == .running }
    }

    private var dockerBlocksStart: Bool {
        project.hasDockerCompose && !appState.canStartProcesses(for: project)
    }

    var body: some View {
        HStack(spacing: 10) {
            ProjectFaviconView(project: project, size: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Button(action: openInBrowser) {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(project.effectiveURL == nil)
                .help("Open in Browser")

                Button(action: openInLaradeck) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Open in Laradeck")
            }
            .opacity(isHovering ? 1 : 0)

            actionPill
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(height: 40, alignment: .center)
        .contentShape(Rectangle())
        .background(Color.primary.opacity(isHovering ? 0.05 : 0))
        .onHover { isHovering = $0 }
    }

    private var subtitle: String {
        var parts: [String] = []
        if project.environment == .sail {
            parts.append("Sail")
        } else if project.hasDockerCompose {
            parts.append("Compose")
        } else {
            parts.append("Native")
        }
        if let port = project.effectiveURL?.port {
            parts.append(":\(port)")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var actionPill: some View {
        if isBusy {
            ProgressView()
                .controlSize(.small)
                .frame(width: 58, height: 22)
        } else {
            Button {
                toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(isRunning ? "Stop" : "Start")
                        .font(.system(size: 11, weight: .medium))
                    StatusDotView(color: appState.health(for: project).color, size: 7)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!isRunning && dockerBlocksStart)
            .help(dockerBlocksStart ? DockerManager.daemonUnavailableMessage : (isRunning ? "Stop All" : "Start All"))
        }
    }

    private func toggle() {
        if isRunning {
            appState.stopAll(project)
        } else {
            appState.startAll(project)
        }
    }

    private func openInBrowser() {
        guard let url = project.effectiveURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func openInLaradeck() {
        appState.selectedProjectId = project.id
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

private struct MenuBarDatabaseRow: View {
    @Environment(AppState.self) private var appState
    let row: DatabaseManager.Row

    @State private var isHovering = false

    private var databases: DatabaseManager { appState.databaseManager }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cylinder.split.1x2.fill")
                .font(.system(size: 14))
                .foregroundStyle(row.service.kind.tint)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.service.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(verbatim: ":\(row.service.port) · \(row.status.label)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if databases.busy.contains(row.id) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 58, height: 22)
            } else {
                Button {
                    databases.toggle(row)
                } label: {
                    HStack(spacing: 6) {
                        Text(row.status == .stopped ? "Start" : "Stop")
                            .font(.system(size: 11, weight: .medium))
                        StatusDotView(color: row.status.color, size: 7)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(height: 36, alignment: .center)
        .contentShape(Rectangle())
        .background(Color.primary.opacity(isHovering ? 0.05 : 0))
        .onHover { isHovering = $0 }
    }
}

private struct MenuBarSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}
