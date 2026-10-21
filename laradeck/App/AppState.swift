import DBEngineKit
import PhpSwitcherCore
import Foundation
import Observation
import ServiceManagement
import AppKit

/// Root store: owns the project list and every service, and bridges persistence + process
/// lifecycle into the UI layer.
@MainActor
@Observable
final class AppState {
    var projects: [Project] = [] {
        didSet { scheduleSave() }
    }
    var presets: [CommandPreset] = [] {
        didSet { store.savePresets(presets) }
    }
    var sidebarGroups: [SidebarGroup] = [] {
        didSet { store.saveSidebarGroups(sidebarGroups) }
    }
    // The detail column shows one of: a project, a database, or the database overview.
    var selectedProjectId: UUID? {
        didSet {
            guard selectedProjectId != nil else { return }
            selectedDatabaseId = nil
            selectedDockerDatabaseId = nil
            selectedServiceId = nil
            showingDatabases = false
            showingPhp = false
            showingNode = false
        }
    }
    var selectedDatabaseId: UUID? {
        didSet {
            guard selectedDatabaseId != nil else { return }
            selectedProjectId = nil
            selectedDockerDatabaseId = nil
            selectedServiceId = nil
            showingDatabases = false
            showingPhp = false
            showingNode = false
        }
    }
    /// `DockerDatabase.id` (project/service) of a database container.
    var selectedDockerDatabaseId: String? {
        didSet {
            guard selectedDockerDatabaseId != nil else { return }
            selectedProjectId = nil
            selectedDatabaseId = nil
            selectedServiceId = nil
            showingDatabases = false
            showingPhp = false
            showingNode = false
        }
    }
    /// A general service (standalone Compose stack) in the sidebar's Services section.
    var selectedServiceId: UUID? {
        didSet {
            guard selectedServiceId != nil else { return }
            selectedProjectId = nil
            selectedDatabaseId = nil
            selectedDockerDatabaseId = nil
            showingDatabases = false
            showingPhp = false
            showingNode = false
        }
    }
    /// The sidebar's "Databases" header was clicked: show every database.
    var showingDatabases = false {
        didSet {
            guard showingDatabases else { return }
            selectedProjectId = nil
            selectedDatabaseId = nil
            selectedDockerDatabaseId = nil
            selectedServiceId = nil
            showingPhp = false
            showingNode = false
        }
    }
    /// The sidebar's "PHP" row: Homebrew PHP versions, extensions, Valet…
    var showingPhp = false {
        didSet {
            guard showingPhp else { return }
            selectedProjectId = nil
            selectedDatabaseId = nil
            selectedDockerDatabaseId = nil
            selectedServiceId = nil
            showingDatabases = false
            showingNode = false
        }
    }
    /// The sidebar's "Node" row: nvm versions.
    var showingNode = false {
        didSet {
            guard showingNode else { return }
            selectedProjectId = nil
            selectedDatabaseId = nil
            selectedDockerDatabaseId = nil
            selectedServiceId = nil
            showingDatabases = false
            showingPhp = false
        }
    }
    /// Set by the menu bar panel's "+" button — the main window observes this to open its own
    /// Add Project sheet, since the two live in separate scenes and can't share sheet state directly.
    var pendingAddProjectRequest = false

    var confirmBeforeStopAll: Bool {
        didSet { UserDefaults.standard.set(confirmBeforeStopAll, forKey: "confirmBeforeStopAll") }
    }
    var launchAtLogin: Bool {
        didSet { updateLoginItem() }
    }
    var preferredTerminal: TerminalApp {
        didSet { UserDefaults.standard.set(preferredTerminal.rawValue, forKey: "preferredTerminal") }
    }

    let processManager: ProcessManager
    let logManager: LogManager
    let notificationManager: NotificationManager
    let dockerManager: DockerManager
    let laravelInstallerMonitor: LaravelInstallerMonitor
    let phpVersionMonitor: PHPVersionMonitor
    let versionCheck: VersionCheckService
    let databaseManager: DatabaseManager
    let generalServices: GeneralServicesManager
    let phpManager: PhpManager
    let nodeManager: NodeManager

    /// In-memory Laravel insights per project — avoids empty→full flash when leaving/returning to the dashboard.
    private(set) var laravelInsightsCache: [UUID: LaravelInsights] = [:]

    /// After Receive .env succeeds, a sheet asks Save / Overwrite / Merge; merge opens the editor.
    var pendingEnvReceive: IncomingEnvPayload?

    /// Shown when Compose Up / Start All would hit host ports already in use.
    var pendingPortConflict: PendingPortConflict?

    /// Shown when Start All finds the project's Laradeck databases stopped.
    var pendingDatabaseStart: PendingDatabaseStart?

    private let store = ProjectStore()
    private var saveTask: Task<Void, Never>?
    private var dockerMonitorTask: Task<Void, Never>?

    init() {
        let logManager = LogManager()
        let notificationManager = NotificationManager()
        self.logManager = logManager
        self.notificationManager = notificationManager
        self.processManager = ProcessManager(notificationManager: notificationManager)
        self.dockerManager = DockerManager(notificationManager: notificationManager)
        self.laravelInstallerMonitor = LaravelInstallerMonitor()
        self.phpVersionMonitor = PHPVersionMonitor()
        self.versionCheck = VersionCheckService()
        self.databaseManager = DatabaseManager()
        self.generalServices = GeneralServicesManager(docker: dockerManager)
        self.phpManager = PhpManager()
        self.nodeManager = NodeManager()

        RuntimeResolver.shared.loadPersistedOverrides()
        #if SPARKLE
        _ = SparkleUpdaterController.shared
        #endif

        self.confirmBeforeStopAll = (UserDefaults.standard.object(forKey: "confirmBeforeStopAll") as? Bool) ?? true
        self.launchAtLogin = SMAppService.mainApp.status == .enabled

        if let savedTerminal = UserDefaults.standard.string(forKey: "preferredTerminal"),
           let terminal = TerminalApp(rawValue: savedTerminal) {
            self.preferredTerminal = terminal
        } else {
            self.preferredTerminal = .terminal
        }

        // One-time cleanup for projects imported before the naming fix — a composer.json package
        // name like "laravel/laravel" isn't a folder name and never should have been used as one.
        let loadedProjects = store.loadProjects().map { project -> Project in
            var project = project
            if project.name.contains("/") {
                project.name = (project.path as NSString).lastPathComponent
            }
            project.ensureOtherCommandsGroup()
            return project
        }
        self.projects = loadedProjects
        self.presets = store.loadPresets()
        if self.presets.isEmpty {
            self.presets = Self.defaultPresets()
        }
        self.sidebarGroups = store.loadSidebarGroups()
        self.selectedProjectId = loadedProjects.first?.id

        // Switching the Homebrew PHP (PHP page, toolbar, or `brew link` in Terminal)
        // updates the toolbar's PHP status right away.
        phpManager.onActiveVersionChanged = { [weak self] in
            Task { await self?.phpVersionMonitor.refresh() }
        }

        processManager.resolveProject = { [weak self] id in
            self?.projects.first { $0.id == id }
        }

        for project in loadedProjects {
            logManager.startTailingLaravelLog(for: project)
            if project.autoStartOnLaunch {
                if project.hasDockerCompose {
                    startAll(project, databases: .start)
                } else {
                    for definition in project.processes where definition.autoStart {
                        processManager.start(definition, in: project, notify: false, nonInteractive: true)
                    }
                }
            }
        }

        startEnvironmentMonitoring()

        Task { [versionCheck] in
            await versionCheck.checkForUpdatesIfNeeded()
        }
    }

    var hasDockerComposeProjects: Bool {
        projects.contains { $0.hasDockerCompose }
    }

    /// Sail processes need a running Docker daemon before start/play is allowed.
    func canStartProcesses(for project: Project) -> Bool {
        guard project.hasDockerCompose else { return true }
        return dockerManager.isDaemonRunning
    }

    func startProcess(_ definition: ProcessDefinition, in project: Project, notify: Bool = true, nonInteractive: Bool = false) {
        guard canStartProcesses(for: project) else {
            notifyDockerDaemonRequired(for: project)
            return
        }
        processManager.start(definition, in: project, notify: notify, nonInteractive: nonInteractive)
    }

    func startProcessWithDependencies(_ definition: ProcessDefinition, in project: Project) async {
        guard canStartProcesses(for: project) else {
            notifyDockerDaemonRequired(for: project)
            return
        }
        await processManager.startWithDependencies(definition, in: project)
    }

    private func notifyDockerDaemonRequired(for project: Project) {
        dockerManager.reportDaemonUnavailable(for: project)
    }

    private func startEnvironmentMonitoring() {
        dockerMonitorTask?.cancel()
        dockerMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Always probe Docker so the sidebar badge stays accurate even without Compose projects.
                await self.dockerManager.refreshDaemonState()
                if self.hasDockerComposeProjects {
                    await self.dockerManager.refreshAllComposeStatuses(for: self.projects)
                }
                await self.laravelInstallerMonitor.refresh()
                await self.phpVersionMonitor.refresh()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// Database containers in Compose / Sail stacks, shown under Databases in the sidebar.
    var dockerDatabases: [DockerDatabase] {
        DockerDatabase.list(projects: projects, statuses: dockerManager.statusByProject)
    }

    func toggleDockerDatabase(_ database: DockerDatabase) {
        guard let project = project(withId: database.projectId) else { return }
        Task {
            if database.isRunning {
                await dockerManager.stop(for: project, service: database.service)
            } else {
                await dockerManager.start(for: project, service: database.service)
            }
            await dockerManager.refreshStatus(for: project)
        }
    }

    /// TablePlus URL using the project's own `.env` credentials (Sail: sail / password).
    func openDockerDatabaseInTablePlus(_ database: DockerDatabase) {
        guard let port = database.hostPort else { return }
        let env = LaravelDetector.readEnvFile(at: database.projectPath)
        let isRedis = database.kind == .redis
        guard let url = DatabaseManager.connectionURL(
            kind: database.kind, port: port,
            user: isRedis ? nil : env["DB_USERNAME"],
            password: isRedis ? env["REDIS_PASSWORD"].flatMap { $0 == "null" ? nil : $0 } : env["DB_PASSWORD"],
            database: isRedis ? nil : env["DB_DATABASE"],
            name: "\(database.projectName) · \(database.service)"
        ) else { return }
        DatabaseManager.openInTablePlus(url)
    }

    /// Switches the Homebrew PHP from global places (sidebar, toolbar, menu bar): the open
    /// detail page closes and the PHP page shows the progress and any follow-up notices.
    func switchPhpShowingProgress(to installation: PhpInstallation) {
        showingPhp = true
        Task { await phpManager.switchTo(installation) }
    }

    /// Running processes of native projects that run the host PHP (`php artisan …`,
    /// `php -S …`). They keep the old version after a switch until restarted.
    var runningHostPhpProcesses: [(definition: ProcessDefinition, project: Project)] {
        projects.filter { $0.environment == .native && !$0.hasDockerCompose }.flatMap { project in
            project.processes.compactMap { definition in
                guard definition.type != .folderWatch,
                      processManager.status(for: definition.id) == .running else { return nil }
                let executable = (definition.executable as NSString).lastPathComponent
                let usesPhp = executable == "php" || executable.hasPrefix("php") || definition.arguments.first == "artisan"
                return usesPhp ? (definition, project) : nil
            }
        }
    }

    func restartHostPhpProcesses() {
        for item in runningHostPhpProcesses {
            processManager.restart(item.definition, in: item.project)
        }
    }

    /// Running processes of a project that run Node from the host (npm/pnpm/yarn scripts,
    /// `composer dev`). They keep the old Node after a change until restarted.
    func runningNodeProcesses(in project: Project) -> [ProcessDefinition] {
        project.processes.filter { definition in
            guard definition.type != .folderWatch,
                  processManager.status(for: definition.id) == .running else { return false }
            let executable = (definition.executable as NSString).lastPathComponent
            if NvmLocator.nodeTools.contains(executable) { return true }
            return executable == "composer" && definition.arguments.contains("dev")
        }
    }

    /// Pins a Node version (nil = nvm default) to a project; running Node processes are
    /// flagged for a restart.
    func setNodeVersion(_ installation: NodeInstallation?, for project: Project) {
        guard var updated = self.project(withId: project.id) else { return }
        let newValue = installation?.version.description
        guard updated.nodeVersion != newValue else { return }
        updated.nodeVersion = newValue
        updateProject(updated)
        if !runningNodeProcesses(in: updated).isEmpty {
            nodeManager.pendingRestart.insert(project.id)
        }
    }

    func restartNodeProcesses(in project: Project) {
        nodeManager.pendingRestart.remove(project.id)
        guard let current = self.project(withId: project.id) else { return }
        for definition in runningNodeProcesses(in: current) {
            processManager.restart(definition, in: current)
        }
    }

    var selectedProject: Project? {
        guard let id = selectedProjectId else { return nil }
        return projects.first { $0.id == id }
    }

    func project(withId id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    func updateProject(_ project: Project) {
        var project = project
        project.ensureOtherCommandsGroup()
        project.ensureStartupSequence()
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index] = project
    }

    func removeProject(_ project: Project) {
        processManager.stopAll(project, notify: false)
        logManager.stopTailingLaravelLog(project: project.id)
        dockerManager.stopContainerLogTails(for: project.id)
        ProjectIconStore.removeIcon(for: project.id)
        laravelInsightsCache.removeValue(forKey: project.id)
        projects.removeAll { $0.id == project.id }
        if selectedProjectId == project.id {
            selectedProjectId = projects.first?.id
        }
    }

    func cachedLaravelInsights(for projectId: UUID) -> LaravelInsights? {
        laravelInsightsCache[projectId]
    }

    func storeLaravelInsights(_ insights: LaravelInsights, for projectId: UUID) {
        laravelInsightsCache[projectId] = insights
    }

    func toggleFavorite(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].favorite.toggle()
    }

    @discardableResult
    func addSidebarGroup(name: String) -> SidebarGroup {
        let group = SidebarGroup(name: name)
        sidebarGroups.append(group)
        return group
    }

    func renameSidebarGroup(_ group: SidebarGroup, to name: String) {
        guard let index = sidebarGroups.firstIndex(where: { $0.id == group.id }) else { return }
        sidebarGroups[index].name = name
    }

    /// Deletes the group; member projects fall back to the ungrouped list rather than being removed.
    func removeSidebarGroup(_ group: SidebarGroup) {
        sidebarGroups.removeAll { $0.id == group.id }
        for index in projects.indices where projects[index].sidebarGroupId == group.id {
            projects[index].sidebarGroupId = nil
        }
    }

    func setSidebarGroupExpanded(_ group: SidebarGroup, isExpanded: Bool) {
        guard let index = sidebarGroups.firstIndex(where: { $0.id == group.id }) else { return }
        sidebarGroups[index].isExpanded = isExpanded
    }

    /// Files the project under `groupId`, appending it after that group's other members so
    /// the sidebar order stays predictable (drop-on-header lands at the bottom of the group).
    func moveProject(_ project: Project, toSidebarGroup groupId: UUID?) {
        guard let fromIndex = projects.firstIndex(where: { $0.id == project.id }) else { return }
        var moved = projects.remove(at: fromIndex)
        moved.sidebarGroupId = groupId
        if let lastInGroup = projects.lastIndex(where: { $0.sidebarGroupId == groupId }) {
            projects.insert(moved, at: lastInGroup + 1)
        } else {
            projects.append(moved)
        }
    }

    /// Drags `draggedId` to sit right before `targetId` in the sidebar's project order,
    /// adopting the target's group so a drag can move a project and reorder it in one step.
    func reorderProject(_ draggedId: UUID, toBefore targetId: UUID) {
        guard draggedId != targetId,
              let fromIndex = projects.firstIndex(where: { $0.id == draggedId }) else { return }
        let targetGroupId = projects.first(where: { $0.id == targetId })?.sidebarGroupId
        var dragged = projects.remove(at: fromIndex)
        dragged.sidebarGroupId = targetGroupId
        let toIndex = projects.firstIndex(where: { $0.id == targetId }) ?? projects.count
        projects.insert(dragged, at: toIndex)
    }

    /// Same as `reorderProject(_:toBefore:)` but drops the project right after `targetId` —
    /// used for the insertion line below the last row of a sidebar section.
    func reorderProject(_ draggedId: UUID, toAfter targetId: UUID) {
        guard draggedId != targetId,
              let fromIndex = projects.firstIndex(where: { $0.id == draggedId }) else { return }
        let targetGroupId = projects.first(where: { $0.id == targetId })?.sidebarGroupId
        var dragged = projects.remove(at: fromIndex)
        dragged.sidebarGroupId = targetGroupId
        let targetIndex = projects.firstIndex(where: { $0.id == targetId }) ?? (projects.count - 1)
        projects.insert(dragged, at: targetIndex + 1)
    }

    /// Drags `groupId` to sit right before `targetId` in the sidebar's group order.
    func reorderSidebarGroup(_ groupId: UUID, toBefore targetId: UUID) {
        guard groupId != targetId,
              let fromIndex = sidebarGroups.firstIndex(where: { $0.id == groupId }) else { return }
        let group = sidebarGroups.remove(at: fromIndex)
        let toIndex = sidebarGroups.firstIndex(where: { $0.id == targetId }) ?? sidebarGroups.count
        sidebarGroups.insert(group, at: toIndex)
    }

    /// Swaps `group` with its neighbor, `offset` positions away (-1 up, +1 down).
    func moveSidebarGroup(_ group: SidebarGroup, offset: Int) {
        guard let index = sidebarGroups.firstIndex(where: { $0.id == group.id }) else { return }
        let newIndex = index + offset
        guard sidebarGroups.indices.contains(newIndex) else { return }
        sidebarGroups.swapAt(index, newIndex)
    }

    func health(for project: Project) -> ProjectHealth {
        let processHealth = processHealth(for: project)
        guard project.hasDockerCompose else { return processHealth }

        let services = dockerManager.statusByProject[project.id] ?? []
        guard !services.isEmpty else { return processHealth }

        return combinedSailHealth(processHealth: processHealth, services: services)
    }

    private func processHealth(for project: Project) -> ProjectHealth {
        let trackable = project.processes.filter {
            $0.type == .longRunning && project.isIncludedInStartAll($0)
        }

        let baseHealth: ProjectHealth
        if trackable.isEmpty {
            baseHealth = .stopped
        } else {
            let statuses = trackable.map { processManager.status(for: $0.id) }
            if statuses.contains(.failed) {
                baseHealth = .error
            } else if statuses.allSatisfy({ $0 == .running }) {
                baseHealth = .running
            } else if statuses.allSatisfy({ $0 == .stopped }) {
                baseHealth = .stopped
            } else {
                baseHealth = .attention
            }
        }

        guard baseHealth == .stopped else { return baseHealth }
        return hasUntrackedRunningProcess(project, excluding: trackable) ? .other : .stopped
    }

    /// True when something outside the tracked Start All set — Other commands, an
    /// excluded custom group, a shortcut — is actually running right now.
    private func hasUntrackedRunningProcess(_ project: Project, excluding trackable: [ProcessDefinition]) -> Bool {
        let trackableIds = Set(trackable.map(\.id))
        return project.processes.contains { definition in
            !trackableIds.contains(definition.id) && processManager.status(for: definition.id) == .running
        }
    }

    private func combinedSailHealth(processHealth: ProjectHealth, services: [DockerServiceStatus]) -> ProjectHealth {
        if processHealth == .error { return .error }
        if services.contains(where: { $0.isUnhealthy || $0.isDead || $0.exitedWithError }) {
            return .error
        }

        let sailAnyRunning = services.contains(where: \.isRunning)
        let sailAllRunning = services.allSatisfy(\.isRunning)
        let sailStarting = services.contains { $0.isRestarting || $0.isHealthCheckStarting }

        if processHealth == .running && sailAllRunning { return .running }
        if processHealth == .stopped && !sailAnyRunning && !sailStarting { return .stopped }
        if processHealth == .other && !sailAnyRunning && !sailStarting { return .other }

        return .attention
    }

    // MARK: - Discovery

    func scanForProjects(rootPaths: [String]) async -> [DiscoveredProject] {
        let existingPaths = Set(projects.map(\.path))
        return await ProjectScanner.scan(rootPaths: rootPaths, existingPaths: existingPaths)
    }

    /// Adds a fully-built `Project` (the wizard already ran detection and let the user review it)
    /// — silently ignores a duplicate path rather than erroring, since drag-and-drop and the scan
    /// list both guard against re-adding, but a race between the two is still possible.
    func addProject(_ project: Project) {
        guard !projects.contains(where: { $0.path == project.path }) else { return }
        var project = project
        project.ensureOtherCommandsGroup()
        projects.append(project)
        selectedProjectId = project.id
        logManager.startTailingLaravelLog(for: project)
        Task {
            if project.hasDockerCompose {
                await dockerManager.refreshDaemonState()
                await dockerManager.refreshStatus(for: project)
            }
            await refreshMetadata(for: project)
        }
    }

    func refreshMetadata(for project: Project) async {
        let metadata = LaravelDetector.detectMetadata(at: project.path)
        let versions = await ProjectMetadataService.refresh(for: project)
        guard var updated = self.project(withId: project.id) else { return }
        updated.laravelVersion = versions.laravelVersion
        updated.phpVersion = versions.phpVersion
        updated.hasHorizon = metadata.hasHorizon
        updated.hasReverb = metadata.hasReverb
        if updated.url == nil || updated.url?.isEmpty == true {
            updated.url = metadata.appURL
        }
        updateProject(updated)
    }

    private static func defaultPresets() -> [CommandPreset] {
        [
            CommandPreset(
                name: "Clear Caches",
                commands: [
                    "php artisan optimize:clear",
                    "php artisan config:clear",
                    "php artisan cache:clear",
                ]
            ),
            CommandPreset(
                name: "Migrate",
                commands: ["php artisan migrate"]
            ),
            CommandPreset(
                name: "Run Tests",
                commands: ["php artisan test"]
            ),
        ]
    }

    // MARK: - Bulk process actions

    /// Runs the project's "Pre-start" processes in sequence (each awaited before the next starts),
    /// brings Sail containers up for a Sail project — the artisan-driven processes run *inside*
    /// them (`sail artisan ...`), so starting those before the containers exist would just fail —
    /// then starts the normal processes, then runs "Post-start".
    /// What Start All does with linked Laradeck databases that are stopped.
    enum LinkedDatabaseDecision {
        /// Show the "databases aren't running" prompt (user-initiated Start All).
        case ask
        /// Start them without asking (prompt's "Start Databases", or autostart at launch).
        case start
        /// Leave them stopped (prompt's "Continue Without").
        case skip
    }

    func startAll(_ project: Project, ignorePortConflicts: Bool = false,
                  databases: LinkedDatabaseDecision = .ask) {
        Task {
            // Daemon state can be stale between monitor ticks — probe before Start All.
            if project.hasDockerCompose {
                await dockerManager.refreshDaemonState()
                if dockerManager.isDaemonRunning {
                    await dockerManager.refreshAllComposeStatuses(for: projects)
                }
            }

            guard canStartProcesses(for: project) else {
                notifyDockerDaemonRequired(for: project)
                return
            }

            if !ignorePortConflicts,
               let report = portConflictReport(for: project, intent: .startAll),
               !report.isEmpty {
                presentPortConflict(report, intent: .startAll)
                return
            }

            switch databases {
            case .ask:
                let stopped = await stoppedLinkedDatabases(for: project)
                if !stopped.isEmpty {
                    presentDatabasePrompt(PendingDatabaseStart(projectId: project.id, services: stopped))
                    return
                }
            case .start:
                await startLinkedDatabases(for: project)
            case .skip:
                break
            }

            await runHookProcesses(.preStart, project: project)

            if project.hasDockerCompose {
                let result = await dockerManager.up(for: project)
                await dockerManager.refreshStatus(for: project)
                // If the containers didn't come up, starting dependent processes would just fail.
                guard result.success else { return }
            }

            await processManager.startAllAndAwait(project)

            await runHookProcesses(.postStart, project: project)
        }
    }

    /// Compose Up with the same port-conflict gate used by Start All.
    func composeUp(_ project: Project, ignorePortConflicts: Bool = false) {
        Task {
            await dockerManager.refreshDaemonState()
            if dockerManager.isDaemonRunning {
                await dockerManager.refreshAllComposeStatuses(for: projects)
            }

            guard canStartProcesses(for: project) else {
                notifyDockerDaemonRequired(for: project)
                return
            }

            if !ignorePortConflicts,
               let report = portConflictReport(for: project, intent: .composeUp),
               !report.isEmpty {
                presentPortConflict(report, intent: .composeUp)
                return
            }

            _ = await dockerManager.up(for: project)
            await dockerManager.refreshStatus(for: project)
        }
    }

    func dismissPortConflict() {
        pendingPortConflict = nil
    }

    func proceedDespitePortConflict() {
        guard let pending = pendingPortConflict else { return }
        let intent = pending.intent
        let projectId = pending.report.projectId
        pendingPortConflict = nil
        guard let project = projects.first(where: { $0.id == projectId }) else { return }
        switch intent {
        case .composeUp:
            composeUp(project, ignorePortConflicts: true)
        case .startAll:
            startAll(project, ignorePortConflicts: true)
        }
    }

    private func presentPortConflict(_ report: PortConflictReport, intent: PortConflictIntent) {
        selectedProjectId = report.projectId
        // Close any open color well — bringing windows forward while a ColorPicker exists
        // otherwise pops NSColorPanel on top of the conflict sheet.
        NSColorPanel.shared.close()
        pendingPortConflict = PendingPortConflict(report: report, intent: intent)
        NSApp.activate(ignoringOtherApps: true)
        // Prefer the main project window; avoid ordering every floating panel (color, etc.).
        if let main = NSApp.windows.first(where: {
            $0.isVisible && $0.canBecomeKey && !($0 is NSPanel)
        }) {
            main.makeKeyAndOrderFront(nil)
        } else {
            NSApp.windows.first(where: \.canBecomeKey)?.makeKeyAndOrderFront(nil)
        }
    }

    private func portConflictReport(for project: Project, intent: PortConflictIntent) -> PortConflictReport? {
        PortConflictService.report(
            for: project,
            allProjects: projects,
            dockerStatuses: dockerManager.statusByProject,
            runningProcessPorts: runningProcessPortOwners(),
            includeComposePorts: project.hasDockerCompose,
            includeProcessPorts: intent == .startAll,
            databasePorts: Dictionary(
                databaseManager.rows.filter(\.isRunning).map { ($0.service.port, $0.service.name) },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    private func runningProcessPortOwners() -> [(projectId: UUID, projectName: String, processName: String, port: Int)] {
        var result: [(projectId: UUID, projectName: String, processName: String, port: Int)] = []
        for project in projects {
            for definition in project.processes {
                guard let port = definition.port, port > 0 else { continue }
                switch processManager.status(for: definition.id) {
                case .running, .starting:
                    result.append((project.id, project.name, definition.name, port))
                case .stopped, .stopping, .failed:
                    continue
                }
            }
        }
        return result
    }

    /// Starts the Laradeck databases a native project's `.env` points at, so migrations and
    /// queue workers find them up. A failure is reported but doesn't block the processes.
    /// Laradeck databases the project's `.env` points at that aren't running right now.
    private func stoppedLinkedDatabases(for project: Project) async -> [Service] {
        let requirements = ProjectDatabaseLink.requirements(for: project)
        guard !requirements.isEmpty else { return [] }
        await databaseManager.refresh()
        let services = databaseManager.rows.map(\.service)
        return requirements
            .compactMap { ProjectDatabaseLink.service(for: $0, in: services) }
            .filter { databaseManager.row(id: $0.id)?.isRunning != true }
    }

    private func presentDatabasePrompt(_ pending: PendingDatabaseStart) {
        pendingDatabaseStart = pending
        bringMainWindowForward()
    }

    /// Answer to the "databases aren't running" prompt.
    func resolveDatabasePrompt(_ decision: LinkedDatabaseDecision?) {
        guard let pending = pendingDatabaseStart else { return }
        pendingDatabaseStart = nil
        guard let decision, let project = project(withId: pending.projectId) else { return }
        // Port conflicts were already checked before the prompt.
        startAll(project, ignorePortConflicts: true, databases: decision)
    }

    private func bringMainWindowForward() {
        NSApp.activate(ignoringOtherApps: true)
        if let main = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey && !($0 is NSPanel) }) {
            main.makeKeyAndOrderFront(nil)
        } else {
            NSApp.windows.first(where: \.canBecomeKey)?.makeKeyAndOrderFront(nil)
        }
    }

    private func startLinkedDatabases(for project: Project) async {
        let requirements = ProjectDatabaseLink.requirements(for: project)
        guard !requirements.isEmpty else { return }
        let services = databaseManager.rows.map(\.service)
        let linked = requirements.compactMap { ProjectDatabaseLink.service(for: $0, in: services) }
        guard !linked.isEmpty else { return }
        let failures = await databaseManager.ensureRunning(linked)
        if !failures.isEmpty {
            let message = failures.joined(separator: "\n")
            databaseManager.error = message
            notificationManager.notifyDatabaseStartFailed(projectName: project.name, message: message)
        }
    }

    /// One-shot hooks are awaited to completion; a long-running hook (e.g. a proxy that needs to
    /// be up but never exits) would make that wait forever, so those are only awaited until
    /// they've started.
    private func runHookProcesses(_ role: ProcessRole, project: Project) async {
        for definition in project.processes where definition.effectiveRole == role {
            startProcess(definition, in: project, notify: false, nonInteractive: true)
            if definition.type == .longRunning {
                await processManager.waitUntilStarted(definition.id)
            } else {
                await processManager.waitForCompletion(definition.id)
            }
        }
    }

    /// Stops the dependent processes first, tears down the Sail containers they were running in,
    /// then runs the project's "Post-stop" hooks.
    func stopAll(_ project: Project) {
        processManager.stopAll(project)

        Task {
            if project.hasDockerCompose {
                await dockerManager.down(for: project)
                await dockerManager.refreshStatus(for: project)
            }
            await runHookProcesses(.postStop, project: project)
        }
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled, let self else { return }
            self.store.saveProjects(self.projects)
        }
    }

    // MARK: - Launch at Login

    private func updateLoginItem() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Best-effort; login item registration failures aren't critical to surface for MVP.
        }
    }
}

/// Start All paused because these linked databases are stopped.
struct PendingDatabaseStart: Identifiable, Equatable {
    let id = UUID()
    let projectId: UUID
    let services: [Service]
}
