import Foundation
import Darwin
import Observation

/// Starts, stops and monitors Laravel/Sail/custom processes via Foundation.Process, over a real
/// pseudo-terminal rather than a plain pipe — color-detecting tools (Symfony Console, chalk,
/// etc.) check `isatty()` and silently print plain text otherwise, which a pipe always fails.
@MainActor
@Observable
final class ProcessManager {
    private(set) var runningProcesses: [UUID: RunningProcess] = [:]
    private(set) var activeSequenceStep: ActiveSequenceStep?
    /// Sequence node ids currently highlighted as a multi-row burst (Start All same-level
    /// siblings, or attached children on manual play), keyed by project — additive so peers
    /// with no pause between them can light up together.
    private var activeAttachedNodes: [UUID: Set<UUID>] = [:]

    private let notificationManager: NotificationManager
    private let runtimeResolver = RuntimeResolver.shared
    private let folderWatchService = FolderWatchService()
    /// Serializes nested child runs so Vite's multi-burst folder writes don't overlap publishes.
    private var watcherChildRunTasks: [UUID: Task<Void, Never>] = [:]
    /// Open PTY master FDs keyed by process definition — kept alive for interactive stdin.
    private var ptySessions: [UUID: PTYSession] = [:]
    /// Live project lookup so folder-watch fires use current nesting / definitions, not the
    /// snapshot captured when the watch was armed.
    var resolveProject: ((UUID) -> Project?)?

    private let stopTimeout: TimeInterval = 5
    private let restartDelay: TimeInterval = 1

    init(notificationManager: NotificationManager) {
        self.notificationManager = notificationManager
    }

    func runningProcess(for definitionId: UUID) -> RunningProcess? {
        runningProcesses[definitionId]
    }

    func status(for definitionId: UUID) -> ProcessStatus {
        runningProcesses[definitionId]?.status ?? .stopped
    }

    /// Whether keystrokes in Logs can be forwarded to this process's PTY master.
    func supportsInteractiveStdin(for definitionId: UUID) -> Bool {
        guard ptySessions[definitionId] != nil else { return false }
        switch status(for: definitionId) {
        case .running, .starting:
            return true
        case .stopped, .stopping, .failed:
            return false
        }
    }

    /// Writes raw bytes to a live process stdin via its PTY master.
    func writeStdin(to definitionId: UUID, data: Data) {
        guard supportsInteractiveStdin(for: definitionId),
              let session = ptySessions[definitionId],
              !data.isEmpty else { return }

        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            let total = data.count
            while offset < total {
                let written = write(
                    session.masterFD,
                    base.advanced(by: offset),
                    total - offset
                )
                if written > 0 {
                    offset += written
                } else if written == -1 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    /// Propagates terminal dimensions to the child process (SIGWINCH via TIOCSWINSZ).
    func setTerminalSize(for definitionId: UUID, cols: Int, rows: Int) {
        guard supportsInteractiveStdin(for: definitionId),
              let session = ptySessions[definitionId] else { return }
        guard cols > 0, rows > 0 else { return }

        var size = winsize(
            ws_row: UInt16(clamping: rows),
            ws_col: UInt16(clamping: cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(session.masterFD, TIOCSWINSZ, &size)
    }

    func setActiveSequenceStep(projectId: UUID, nodeId: UUID, delayRemaining: Int? = nil) {
        activeSequenceStep = ActiveSequenceStep(
            projectId: projectId,
            nodeId: nodeId,
            delayRemaining: delayRemaining
        )
    }

    func clearActiveSequenceStep(projectId: UUID) {
        if activeSequenceStep?.projectId == projectId {
            activeSequenceStep = nil
        }
        activeAttachedNodes[projectId] = nil
    }

    /// Node id for `processId` if it's an attached (nested) sequence step — top-level steps use
    /// `activeSequenceStep` instead, so they're excluded here.
    private func attachedSequenceNodeId(for processId: UUID, in project: Project) -> UUID? {
        guard project.nestedStartupProcessIds().contains(processId) else { return nil }
        return StartupSequence.nodeForProcessId(processId, in: project.effectiveStartupSequence)?.id
    }

    func activateSequenceNode(projectId: UUID, nodeId: UUID) {
        activeAttachedNodes[projectId, default: []].insert(nodeId)
    }

    func deactivateSequenceNode(projectId: UUID, nodeId: UUID) {
        activeAttachedNodes[projectId]?.remove(nodeId)
        if activeAttachedNodes[projectId]?.isEmpty == true {
            activeAttachedNodes[projectId] = nil
        }
    }

    /// Whether a sequence row is in the current multi-node burst highlight — used by the UI
    /// alongside the single `activeSequenceStep` (delays / primary cursor).
    func isAttachedNodeActive(projectId: UUID, nodeId: UUID) -> Bool {
        activeAttachedNodes[projectId]?.contains(nodeId) ?? false
    }

    func runSequenceDelay(seconds: Int, projectId: UUID, nodeId: UUID) async {
        guard seconds > 0 else { return }
        for remaining in stride(from: seconds, through: 1, by: -1) {
            setActiveSequenceStep(projectId: projectId, nodeId: nodeId, delayRemaining: remaining)
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private var completionWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var startedWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    /// Suspends until the given process's current run finishes (any terminal status) — used to
    /// await one-shot pre-start/post-start hooks in sequence before continuing. Returns
    /// immediately if the process isn't currently running/starting.
    func waitForCompletion(_ definitionId: UUID) async {
        let current = status(for: definitionId)
        guard current == .running || current == .starting else { return }
        await withCheckedContinuation { continuation in
            completionWaiters[definitionId, default: []].append(continuation)
        }
    }

    /// Suspends until the given process has left `.starting` (either reached `.running`, or
    /// failed to) — used for a *long-running* pre-start/post-start hook, where waiting for it to
    /// finish would wait forever; being up is enough to move on.
    func waitUntilStarted(_ definitionId: UUID) async {
        guard status(for: definitionId) == .starting else { return }
        await withCheckedContinuation { continuation in
            startedWaiters[definitionId, default: []].append(continuation)
        }
    }

    private func resumeCompletionWaiters(for definitionId: UUID) {
        let waiters = completionWaiters.removeValue(forKey: definitionId) ?? []
        for continuation in waiters {
            continuation.resume()
        }
    }

    private func resumeStartedWaiters(for definitionId: UUID) {
        let waiters = startedWaiters.removeValue(forKey: definitionId) ?? []
        for continuation in waiters {
            continuation.resume()
        }
    }

    /// Called from `applicationWillTerminate` / `applicationShouldTerminate` — without this, every
    /// process we started (php artisan serve workers, npm run dev, queue workers…) is orphaned and
    /// keeps running after Laradeck quits. Synchronous and bounded (~2s): SIGTERM the whole process
    /// group first (so PHP_CLI_SERVER_WORKERS children die too), then SIGKILL survivors.
    func stopAllProcessesForAppTermination() {
        folderWatchService.stopAll()

        let roots = runningProcesses.values.compactMap(\.pid)
        guard !roots.isEmpty else { return }

        signalProcessTrees(roots: roots, signal: SIGTERM)

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let stillAlive = roots.contains { isProcessAlive($0) } || roots.contains { !descendantPids(of: $0).isEmpty }
            if !stillAlive { break }
            usleep(100_000)
        }

        signalProcessTrees(roots: roots, signal: SIGKILL)
    }

    /// Sends `signal` to each root, its process group (`-pid`), and known descendants.
    private func signalProcessTrees(roots: [Int32], signal: Int32) {
        var targets = Set<Int32>()
        for root in roots {
            targets.insert(root)
            targets.formUnion(descendantPids(of: root))
        }
        for pid in targets {
            // Negative pid = process group (workers usually share the leader's group).
            kill(-pid, signal)
            kill(pid, signal)
        }
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    /// Best-effort child walk via `sysctl` — covers workers that left the process group.
    private func descendantPids(of root: Int32) -> [Int32] {
        let all = allProcessInfos()
        var childrenByParent: [Int32: [Int32]] = [:]
        for info in all {
            childrenByParent[info.ppid, default: []].append(info.pid)
        }
        var result: [Int32] = []
        var queue = childrenByParent[root] ?? []
        var seen = Set<Int32>([root])
        while let pid = queue.first {
            queue.removeFirst()
            guard seen.insert(pid).inserted else { continue }
            result.append(pid)
            queue.append(contentsOf: childrenByParent[pid] ?? [])
        }
        return result
    }

    private struct ProcEntry {
        var pid: Int32
        var ppid: Int32
    }

    private func allProcessInfos() -> [ProcEntry] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var length = 0
        guard sysctl(&name, u_int(name.count), nil, &length, nil, 0) == 0, length > 0 else {
            return []
        }
        let count = length / MemoryLayout<kinfo_proc>.stride
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: count)
        let result = buffer.withUnsafeMutableBufferPointer { ptr in
            sysctl(&name, u_int(name.count), ptr.baseAddress, &length, nil, 0)
        }
        guard result == 0 else { return [] }
        let actualCount = length / MemoryLayout<kinfo_proc>.stride
        return buffer.prefix(actualCount).map {
            ProcEntry(pid: $0.kp_proc.p_pid, ppid: $0.kp_eproc.e_ppid)
        }
    }

    // MARK: - Start / Stop / Restart

    func start(
        _ definition: ProcessDefinition,
        in project: Project,
        notify: Bool = true,
        armAttachedChildren: Bool = true,
        nonInteractive: Bool = false
    ) {
        let current = status(for: definition.id)
        guard current != .running, current != .starting else { return }

        let running = runningProcesses[definition.id] ?? RunningProcess(id: definition.id, projectId: project.id)
        running.notifyActivity = notify
        running.notifyOnStop = notify
        running.status = .starting
        running.exitCode = nil
        runningProcesses[definition.id] = running

        // Lights up attached rows on manual play. Start All drives `activeSequenceStep` itself
        // (highlight before start), so skip the parallel attached-node set there.
        let attachedNodeId = armAttachedChildren
            ? attachedSequenceNodeId(for: definition.id, in: project)
            : nil
        if let attachedNodeId {
            activateSequenceNode(projectId: project.id, nodeId: attachedNodeId)
        }

        if definition.type == .folderWatch {
            Task { [weak self] in
                await self?.launchFolderWatch(definition: definition, project: project, running: running)
                if let attachedNodeId {
                    self?.deactivateSequenceNode(projectId: project.id, nodeId: attachedNodeId)
                }
            }
            return
        }

        Task { [weak self] in
            await self?.launch(
                definition: definition,
                project: project,
                running: running,
                nonInteractive: nonInteractive
            )
            if let attachedNodeId {
                // Sail/Docker-style tools often exit in the first second — keep the row lit through
                // that settle window so a fast failure still shows up highlighted.
                if definition.type == .longRunning {
                    try? await Task.sleep(for: .milliseconds(900))
                }
                self?.deactivateSequenceNode(projectId: project.id, nodeId: attachedNodeId)
            }
            // Nested one-shots stay manual / folder-watch driven; persistent attaches arm with the
            // parent on manual play. Start All passes `armAttachedChildren: false` and walks the
            // tree itself so pauses between nested siblings aren't double-handled.
            if armAttachedChildren {
                await self?.startAttachedPersistentChildren(of: definition, in: project, notify: notify)
            }
        }
    }

    /// After a long-running parent is up, start nested long-running / folder-watch children.
    /// Folder-watch parents never boot their children here (those run on filesystem changes).
    private func startAttachedPersistentChildren(
        of definition: ProcessDefinition,
        in project: Project,
        notify: Bool
    ) async {
        guard definition.type != .folderWatch else { return }

        await waitUntilStarted(definition.id)
        if definition.type == .longRunning {
            try? await Task.sleep(for: .milliseconds(900))
        }
        guard status(for: definition.id) == .running else { return }

        guard let node = StartupSequence.nodeForProcessId(
            definition.id,
            in: project.effectiveStartupSequence
        ), !node.children.isEmpty else { return }

        await startChildren(node.children, in: project, notify: notify)
    }

    /// Starts attached children in order on manual play.
    /// Consecutive processes with no pause arm together; a Pause node blocks whatever follows.
    private func startChildren(_ nodes: [StartupSequenceNode], in project: Project, notify: Bool) async {
        var index = 0
        while index < nodes.count {
            switch nodes[index].kind {
            case .delay(let seconds):
                await runSequenceDelay(seconds: seconds, projectId: project.id, nodeId: nodes[index].id)
                index += 1

            case .process:
                var burst: [StartupSequenceNode] = []
                while index < nodes.count {
                    if case .process = nodes[index].kind {
                        burst.append(nodes[index])
                        index += 1
                    } else {
                        break
                    }
                }
                for node in burst {
                    guard case .process(let childId) = node.kind,
                          let childDefinition = project.process(withId: childId) else { continue }
                    switch childDefinition.type {
                    case .longRunning, .folderWatch:
                        let childStatus = status(for: childId)
                        guard childStatus != .running, childStatus != .starting else { continue }
                        // Nested grandchildren arm when *this* child comes up (manual play).
                        start(childDefinition, in: project, notify: notify, armAttachedChildren: true)
                    case .oneShot, .shortcut:
                        continue
                    }
                }
            }
        }
    }

    func stop(_ definition: ProcessDefinition, in project: Project? = nil, notify: Bool? = nil) {
        if let project {
            stopAttachedPersistentChildren(of: definition, in: project, notify: notify)
        }

        if definition.type == .folderWatch {
            stopFolderWatch(definition, notify: notify)
            return
        }

        guard let running = runningProcesses[definition.id], let task = running.task, task.isRunning else { return }
        if let notify {
            running.notifyOnStop = notify
        }
        running.status = .stopping

        let pid = running.pid ?? task.processIdentifier
        signalProcessTrees(roots: [pid], signal: SIGTERM)
        // Also ask Foundation — covers the rare case setpgid failed and the tree walk misses.
        task.terminate()

        Task {
            try? await Task.sleep(for: .seconds(stopTimeout))
            if running.status == .stopping {
                signalProcessTrees(roots: [pid], signal: SIGKILL)
            }
        }
    }

    /// Stops nested long-running / folder-watch children that were armed with this parent.
    private func stopAttachedPersistentChildren(
        of definition: ProcessDefinition,
        in project: Project,
        notify: Bool?
    ) {
        guard definition.type != .folderWatch,
              let node = StartupSequence.nodeForProcessId(
                definition.id,
                in: project.effectiveStartupSequence
              ) else { return }

        for child in node.children {
            guard case .process(let childId) = child.kind,
                  let childDefinition = project.process(withId: childId),
                  childDefinition.type == .longRunning || childDefinition.type == .folderWatch else { continue }
            stop(childDefinition, in: project, notify: notify)
        }
    }

    func restart(_ definition: ProcessDefinition, in project: Project) {
        if definition.type == .folderWatch {
            stop(definition, in: project, notify: false)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.restartDelay ?? 1))
                self?.start(definition, in: project, notify: true, nonInteractive: true)
            }
            return
        }
        stop(definition, in: project, notify: false)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.restartDelay ?? 1))
            self?.start(definition, in: project, notify: true, nonInteractive: true)
        }
    }

    func startWithDependencies(_ definition: ProcessDefinition, in project: Project) async {
        defer { clearActiveSequenceStep(projectId: project.id) }
        await StartupSequenceRunner.runUntilProcess(
            definition.id,
            sequence: project.effectiveStartupSequence,
            project: project,
            manager: self
        )
    }

    func startAll(_ project: Project) {
        Task { await startAllAndAwait(project) }
    }

    /// Starts the project's Start All sequence and waits until notifications have been decided.
    func startAllAndAwait(_ project: Project) async {
        defer { clearActiveSequenceStep(projectId: project.id) }
        var outcome = await StartupSequenceRunner.runSequence(
            project.effectiveStartupSequence,
            project: project,
            manager: self,
            notify: false
        )

        // Re-check after a short settle — Sail/Docker often exits in the first second after "start".
        outcome = reconcileStartAllOutcome(outcome, project: project)

        guard outcome.attemptedAny || !outcome.failedNames.isEmpty else { return }

        if outcome.allSucceeded {
            notificationManager.notifyAllProcessesStarted(projectName: project.name)
        } else {
            notificationManager.notifyAllProcessesStartedWithFailures(
                projectName: project.name,
                failedProcessNames: outcome.failedNames
            )
        }
    }

    /// Final pass: any Start All long-running process that isn't running counts as failed.
    private func reconcileStartAllOutcome(
        _ outcome: StartupSequenceOutcome,
        project: Project
    ) -> StartupSequenceOutcome {
        var result = outcome
        let startable = project.processes.filter { project.isIncludedInStartAll($0) }

        for definition in startable {
            switch status(for: definition.id) {
            case .running:
                continue
            case .failed:
                if !result.failedNames.contains(definition.name) {
                    result.failedNames.append(definition.name)
                }
            case .stopped:
                if definition.type == .longRunning || definition.type == .folderWatch {
                    if !result.failedNames.contains(definition.name) {
                        result.failedNames.append(definition.name)
                    }
                } else if let code = runningProcess(for: definition.id)?.exitCode, code != 0 {
                    if !result.failedNames.contains(definition.name) {
                        result.failedNames.append(definition.name)
                    }
                }
            case .starting, .stopping:
                if !result.failedNames.contains(definition.name) {
                    result.failedNames.append(definition.name)
                }
            }
        }

        if result.attempted == 0, !result.failedNames.isEmpty {
            result.attempted = result.failedNames.count
        }
        return result
    }

    func stopAll(_ project: Project, notify: Bool = true) {
        let stoppable = project.processes.filter { project.isIncludedInStopAll($0) }
        let anyActive = stoppable.contains {
            switch status(for: $0.id) {
            case .running, .starting, .stopping: return true
            case .stopped, .failed: return false
            }
        }

        for definition in stoppable {
            stop(definition, notify: false)
        }

        // Clear failed badges too — Stop All should leave every process looking clean/stopped.
        clearFailedStatuses(for: project)

        if notify, anyActive {
            notificationManager.notifyAllProcessesStopped(projectName: project.name)
        }
    }

    /// Resets red "failed" status dots back to stopped (no process to terminate).
    func clearFailedStatuses(for project: Project) {
        for definition in project.processes {
            guard let running = runningProcesses[definition.id], running.status == .failed else { continue }
            running.status = .stopped
            running.exitCode = nil
        }
    }

    // MARK: - Folder watch

    private func launchFolderWatch(
        definition: ProcessDefinition,
        project: Project,
        running: RunningProcess
    ) async {
        defer { resumeStartedWaiters(for: definition.id) }

        let resolved = FolderWatchPathResolver.resolveAll(definition.watchPaths, projectPath: project.path)
        guard !resolved.isEmpty else {
            running.status = .failed
            let reason = "Folder watch has no paths configured."
            running.appendTerminalText(reason)
            notificationManager.notifyProcessStartFailure(
                projectName: project.name,
                processName: definition.name,
                reason: reason
            )
            return
        }

        let warning = folderWatchService.start(
            id: definition.id,
            directoryPaths: resolved,
            debounceMs: definition.watchDebounceMs,
            onDebouncedChange: { [weak self] in
                self?.fireWatcherChildren(watcherId: definition.id, project: project)
            },
            onLog: { [weak self] message in
                self?.runningProcesses[definition.id]?.appendTerminalText(message)
            }
        )

        // nil = full success; "Watching with warnings:…" = partial; anything else = hard fail.
        if let warning, !warning.hasPrefix("Watching with warnings") {
            running.status = .failed
            running.appendTerminalText(warning)
            notificationManager.notifyProcessStartFailure(
                projectName: project.name,
                processName: definition.name,
                reason: warning
            )
            return
        }

        running.status = .running
        running.startTime = Date()
        running.appendTerminalText("Watching \(resolved.joined(separator: ", ")) · \(definition.watchDebounceMs)ms debounce")
        if let warning {
            running.appendTerminalText(warning)
        }
        if running.notifyActivity {
            notificationManager.notifyProcessStarted(processName: definition.name)
        }
    }

    private func stopFolderWatch(_ definition: ProcessDefinition, notify: Bool?) {
        guard let running = runningProcesses[definition.id] else {
            folderWatchService.stop(id: definition.id)
            return
        }
        watcherChildRunTasks[definition.id]?.cancel()
        watcherChildRunTasks[definition.id] = nil
        let shouldNotify = notify ?? running.notifyOnStop
        let wasActive = running.status == .running || running.status == .starting || running.status == .stopping
        folderWatchService.stop(id: definition.id)
        running.status = .stopped
        running.pid = nil
        running.task = nil
        running.appendTerminalText("Stopped watching.")
        resumeCompletionWaiters(for: definition.id)
        if shouldNotify, wasActive {
            notificationManager.notifyProcessStopped(processName: definition.name)
        }
    }

    /// Runs nested Start All children of this watcher after a debounced filesystem change.
    func fireWatcherChildren(watcherId: UUID, project: Project) {
        guard status(for: watcherId) == .running,
              let watcher = project.process(withId: watcherId),
              watcher.type == .folderWatch else { return }

        // Prefer the live project so nesting edits after "Watch" started still apply.
        let project = resolveProject?(project.id) ?? project

        guard let node = StartupSequence.nodeForProcessId(watcherId, in: project.effectiveStartupSequence),
              !node.children.isEmpty else {
            runningProcesses[watcherId]?.appendTerminalText("Change detected — no nested processes to run.")
            return
        }

        // Nested run already going — FolderWatchService suppresses and may settle-fire later.
        if watcherChildRunTasks[watcherId] != nil {
            runningProcesses[watcherId]?.appendTerminalText("Change detected — nested run already in progress.")
            return
        }

        if let note = folderWatchService.consumeChangeNote(id: watcherId) {
            runningProcesses[watcherId]?.appendTerminalText("Change detected (\(note))")
        }

        let childCount = node.children.count
        runningProcesses[watcherId]?.appendTerminalText(
            "Starting \(childCount) nested step\(childCount == 1 ? "" : "s")…"
        )

        folderWatchService.beginSuppressing(id: watcherId)
        watcherChildRunTasks[watcherId] = Task { [weak self] in
            guard let self else { return }
            await self.runWatcherChildren(node.children, project: project, watcherId: watcherId)
            self.watcherChildRunTasks[watcherId] = nil
            self.folderWatchService.endSuppressing(id: watcherId)
        }
    }

    private func runWatcherChildren(
        _ nodes: [StartupSequenceNode],
        project: Project,
        watcherId: UUID
    ) async {
        for node in nodes {
            switch node.kind {
            case .delay(let seconds):
                if seconds > 0 {
                    runningProcesses[watcherId]?.appendTerminalText("Nested pause \(seconds)s…")
                    try? await Task.sleep(for: .seconds(seconds))
                }
            case .process(let processId):
                guard let definition = project.process(withId: processId) else {
                    runningProcesses[watcherId]?.appendTerminalText(
                        "Skipped nested process — definition missing (\(processId.uuidString.prefix(8))…)."
                    )
                    continue
                }

                // Nested under a folder watch is the opt-in: run even when the child lives in
                // Other commands / is typed longRunning (the sheet default) and would be
                // excluded from Start All.
                await runWatcherChild(definition, in: project, watcherId: watcherId)
            }

            if !node.children.isEmpty {
                await runWatcherChildren(node.children, project: project, watcherId: watcherId)
            }
        }
    }

    private func runWatcherChild(
        _ definition: ProcessDefinition,
        in project: Project,
        watcherId: UUID
    ) async {
        let log: (String) -> Void = { [weak self] message in
            self?.runningProcesses[watcherId]?.appendTerminalText(message)
        }

        switch definition.type {
        case .folderWatch:
            log("Skipped nested \(definition.name) — folder watches can't nest under a folder watch.")
            return

        case .longRunning:
            let current = status(for: definition.id)
            if current == .running || current == .starting {
                // Re-run on each change: stop the previous instance first.
                log("Restarting nested \(definition.name)…")
                stop(definition, in: project, notify: false)
                await waitForCompletion(definition.id)
            } else {
                log("Running nested \(definition.name)…")
            }
            start(definition, in: project, notify: false, armAttachedChildren: false, nonInteractive: true)
            await waitUntilStarted(definition.id)
            // Hold suppress briefly so short-lived "long running" commands (publish scripts
            // left on the default type) can finish writing before the watch re-arms.
            for _ in 0..<20 {
                let s = status(for: definition.id)
                if s != .running && s != .starting { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if status(for: definition.id) == .running {
                log("Nested \(definition.name) is up.")
            } else if status(for: definition.id) == .failed {
                log("Nested \(definition.name) failed.")
            } else {
                log("Nested \(definition.name) finished.")
            }

        case .oneShot, .shortcut:
            await waitForCompletion(definition.id)
            log("Running nested \(definition.name)…")
            start(definition, in: project, notify: false, armAttachedChildren: false, nonInteractive: true)
            await waitForCompletion(definition.id)
            if let code = runningProcess(for: definition.id)?.exitCode {
                log("Nested \(definition.name) finished (exit \(code)).")
            } else {
                log("Nested \(definition.name) finished.")
            }
        }
    }

    // MARK: - Launch

    private struct PTYSession {
        let masterFD: Int32
        let readSource: DispatchSourceRead
    }

    private func teardownPTY(for definitionId: UUID) {
        guard let session = ptySessions.removeValue(forKey: definitionId) else { return }
        session.readSource.cancel()
        if session.masterFD >= 0 {
            close(session.masterFD)
        }
        runningProcesses[definitionId]?.hasInteractivePTY = false
    }

    private func launch(
        definition: ProcessDefinition,
        project: Project,
        running: RunningProcess,
        nonInteractive: Bool
    ) async {
        // Every path out of this function — success or one of the failure returns below — means
        // the process has either started running or definitively failed to; either way, anyone
        // waiting on `waitUntilStarted` can stop waiting.
        defer { resumeStartedWaiters(for: definition.id) }

        guard let executablePath = await resolveExecutable(definition.executable, project: project) else {
            running.status = .failed
            let reason = "Could not resolve executable '\(definition.executable)'."
            running.appendTerminalText(reason)
            notificationManager.notifyProcessStartFailure(
                projectName: project.name,
                processName: definition.name,
                reason: reason
            )
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        var launchArguments = definition.arguments
        if nonInteractive && !definition.isInteractiveCommand {
            launchArguments = NonInteractiveCommandFlags.arguments(
                executable: definition.executable,
                resolvedExecutablePath: executablePath,
                arguments: launchArguments
            )
        }
        process.arguments = launchArguments

        let workingDirectory = definition.workingDirectory ?? project.path
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)

        var environment = await runtimeResolver.loginShellEnvironment()
        if environment.isEmpty {
            environment = ProcessInfo.processInfo.environment
        }
        // The Node version chosen for this project (nvm), like `nvm use` in Terminal.
        NvmLocator.apply(to: &environment, for: project)
        for (key, value) in definition.environment {
            environment[key] = value
        }
        // Matches a real terminal so color-detecting tools behave the same as in Terminal/iTerm.
        environment["TERM"] = "xterm-256color"
        process.environment = environment

        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
            running.status = .failed
            let reason = "Could not allocate a pseudo-terminal."
            running.appendTerminalText(reason)
            notificationManager.notifyProcessStartFailure(
                projectName: project.name,
                processName: definition.name,
                reason: reason
            )
            return
        }

        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        // Raw POSIX read, not FileHandle.availableData: once the slave side closes, reading the
        // master can fail with a POSIX error rather than a clean EOF, and availableData raises an
        // *Objective-C* exception in that case — one Swift can't catch, so it takes the app down.
        let readSource = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: .global(qos: .utility))
        readSource.setEventHandler { [weak running] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            var bytesRead = 0
            repeat {
                bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                    read(masterFD, rawBuffer.baseAddress, rawBuffer.count)
                }
            } while bytesRead == -1 && errno == EINTR

            guard bytesRead > 0 else {
                readSource.cancel()
                return
            }

            let data = Data(buffer[0..<bytesRead])
            Task { @MainActor in
                running?.appendTerminalBytes(data)
            }
        }
        readSource.setCancelHandler {}
        readSource.resume()

        ptySessions[definition.id] = PTYSession(masterFD: masterFD, readSource: readSource)
        running.hasInteractivePTY = true

        process.terminationHandler = { [weak self] finishedProcess in
            readSource.cancel()
            Task { @MainActor in
                self?.teardownPTY(for: definition.id)
                self?.handleTermination(finishedProcess, definition: definition, project: project, running: running)
            }
        }

        do {
            try process.run()
        } catch {
            teardownPTY(for: definition.id)
            close(slaveFD)
            running.status = .failed
            let reason = error.localizedDescription
            running.appendTerminalText("Failed to start: \(reason)")
            notificationManager.notifyProcessStartFailure(
                projectName: project.name,
                processName: definition.name,
                reason: reason
            )
            return
        }

        // The child has its own copy (dup'd during spawn) — closing ours lets master reads see
        // EOF once the child actually exits, instead of hanging open indefinitely.
        close(slaveFD)

        let pid = process.processIdentifier
        // Own process group so Stop All / quit can SIGTERM the whole tree (PHP workers, npm children).
        _ = setpgid(pid, pid)

        running.task = process
        running.pid = pid
        running.startTime = Date()
        running.status = .running
        if running.notifyActivity {
            notificationManager.notifyProcessStarted(processName: definition.name)
        }
    }

    private func handleTermination(_ process: Process, definition: ProcessDefinition, project: Project, running: RunningProcess) {
        let exitCode = process.terminationStatus
        let wasIntentionalStop = running.status == .stopping

        running.exitCode = exitCode
        running.pid = nil
        running.task = nil

        if wasIntentionalStop {
            running.status = .stopped
            if running.notifyOnStop {
                notificationManager.notifyProcessStopped(processName: definition.name)
            }
        } else if exitCode != 0 {
            running.status = .failed
            running.appendTerminalText("Process exited unexpectedly with code \(exitCode).")
            notificationManager.notifyProcessUnexpectedExit(
                projectName: project.name,
                processName: definition.name,
                exitCode: exitCode
            )
        } else {
            running.status = .stopped
        }

        resumeCompletionWaiters(for: definition.id)

        let shouldRestart: Bool
        switch definition.restartPolicy {
        case .never: shouldRestart = false
        case .onFailure: shouldRestart = !wasIntentionalStop && exitCode != 0
        case .always: shouldRestart = !wasIntentionalStop
        }

        guard shouldRestart else { return }

        if running.recordRestartAndCheckLoop() {
            running.status = .failed
            running.appendTerminalText("Restart loop detected (more than 5 restarts within 60s) — giving up.")
            notificationManager.notifyProcessRestartLoop(
                projectName: project.name,
                processName: definition.name
            )
            return
        }

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.restartDelay ?? 1))
            self?.start(definition, in: project, notify: false, nonInteractive: true)
        }
    }

    private func resolveExecutable(_ name: String, project: Project) async -> String? {
        if name.hasPrefix("/") {
            return name
        }
        if name == "sail" {
            if let sailPath = runtimeResolver.sailBinary(inProject: project.path) {
                return sailPath
            }
            return await runtimeResolver.resolvePath(for: "sail")
        }
        if NvmLocator.nodeTools.contains(name), let bin = NvmLocator.binDirectory(for: project) {
            let candidate = (bin as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return await runtimeResolver.resolvePath(for: name)
    }
}
