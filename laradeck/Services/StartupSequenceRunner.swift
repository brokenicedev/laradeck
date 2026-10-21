import Foundation

/// Outcome of a Start All / sequence run — used for accurate notifications.
struct StartupSequenceOutcome: Equatable, Sendable {
    var attempted: Int = 0
    var succeeded: Int = 0
    var failedNames: [String] = []

    var attemptedAny: Bool { attempted > 0 }
    var allSucceeded: Bool { attempted > 0 && failedNames.isEmpty }
}

/// Executes a project's visual startup sequence for Start All and manual starts.
///
/// Same-level siblings with no pause between them arm together; pauses only block what
/// follows at that same level. Nested children run after their parent settles — they do
/// not hold back peer siblings:
/// ```
/// Web Server          ┐
///   Scheduler         │ nested: Scheduler → pause → Reverb
///   pause
///   Reverb            │
/// Queue Worker        ┘  ← Queue + Agno start with Web Server (same level)
/// Agno Agents
/// ```
nonisolated enum StartupSequenceRunner {
    @MainActor
    static func runSequence(
        _ nodes: [StartupSequenceNode],
        project: Project,
        manager: ProcessManager,
        notify: Bool
    ) async -> StartupSequenceOutcome {
        let startable = Set(project.processes.filter { project.isIncludedInStartAll($0) }.map(\.id))
        return await runNodes(nodes, project: project, manager: manager, startable: startable, notify: notify)
    }

    @MainActor
    static func runUntilProcess(_ processId: UUID, sequence: [StartupSequenceNode], project: Project, manager: ProcessManager) async {
        let prerequisites = StartupSequence.prerequisites(for: processId, in: sequence)
        let startable = Set(project.processes.filter { project.isIncludedInStartAll($0) }.map(\.id))
        _ = await runNodes(prerequisites, project: project, manager: manager, startable: startable, notify: true)
        if let definition = project.process(withId: processId) {
            // Manual play still arms attached children (with their own pauses) via ProcessManager.
            manager.start(definition, in: project, notify: true, armAttachedChildren: true)
        }
    }

    @MainActor
    private static func runNodes(
        _ nodes: [StartupSequenceNode],
        project: Project,
        manager: ProcessManager,
        startable: Set<UUID>,
        notify: Bool
    ) async -> StartupSequenceOutcome {
        var outcome = StartupSequenceOutcome()
        var index = 0

        while index < nodes.count {
            switch nodes[index].kind {
            case .delay(let seconds):
                let node = nodes[index]
                manager.setActiveSequenceStep(projectId: project.id, nodeId: node.id)
                await manager.runSequenceDelay(seconds: seconds, projectId: project.id, nodeId: node.id)
                index += 1

            case .process:
                // Consecutive process rows with no pause between them = one burst.
                var burst: [StartupSequenceNode] = []
                while index < nodes.count {
                    if case .process = nodes[index].kind {
                        burst.append(nodes[index])
                        index += 1
                    } else {
                        break
                    }
                }

                let started = await startBurst(
                    burst,
                    project: project,
                    manager: manager,
                    startable: startable,
                    notify: notify
                )
                outcome.attempted += started.attempted
                outcome.succeeded += started.succeeded
                outcome.failedNames.append(contentsOf: started.failedNames)

                // Nested steps for each parent — peers in the burst are already up.
                for node in burst {
                    guard case .process(let processId) = node.kind,
                          let definition = project.process(withId: processId),
                          !node.children.isEmpty,
                          manager.status(for: processId) == .running,
                          definition.type != .folderWatch else { continue }

                    let nested = await runNodes(
                        node.children,
                        project: project,
                        manager: manager,
                        startable: startable,
                        notify: notify
                    )
                    outcome.attempted += nested.attempted
                    outcome.succeeded += nested.succeeded
                    outcome.failedNames.append(contentsOf: nested.failedNames)
                }
            }
        }

        return outcome
    }

    /// Lights up every row in the burst, starts them together, then waits for settle.
    @MainActor
    private static func startBurst(
        _ burst: [StartupSequenceNode],
        project: Project,
        manager: ProcessManager,
        startable: Set<UUID>,
        notify: Bool
    ) async -> StartupSequenceOutcome {
        var outcome = StartupSequenceOutcome()
        var launched: [(node: StartupSequenceNode, definition: ProcessDefinition)] = []

        for node in burst {
            guard case .process(let processId) = node.kind,
                  startable.contains(processId),
                  let definition = project.process(withId: processId) else { continue }
            launched.append((node, definition))
        }

        guard !launched.isEmpty else { return outcome }

        // Highlight the whole burst before any status flips to green.
        for item in launched {
            manager.activateSequenceNode(projectId: project.id, nodeId: item.node.id)
        }
        if let first = launched.first {
            manager.setActiveSequenceStep(projectId: project.id, nodeId: first.node.id)
        }
        try? await Task.sleep(for: .milliseconds(50))

        for item in launched {
            let alreadyRunning = manager.status(for: item.definition.id) == .running
            if !alreadyRunning, manager.status(for: item.definition.id) != .starting {
                manager.start(item.definition, in: project, notify: notify, armAttachedChildren: false, nonInteractive: true)
            }
        }

        // Wait for the whole burst to leave `.starting`, then one shared settle window.
        for item in launched {
            while manager.status(for: item.definition.id) == .starting {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let needsSettle = launched.contains {
            $0.definition.type == .longRunning || $0.definition.type == .folderWatch
        }
        if needsSettle {
            try? await Task.sleep(for: .milliseconds(900))
        }

        for item in launched {
            outcome.attempted += 1
            switch evaluateAfterStart(processId: item.definition.id, definition: item.definition, manager: manager) {
            case .succeeded:
                outcome.succeeded += 1
            case .failed:
                outcome.failedNames.append(item.definition.name)
            }
            manager.deactivateSequenceNode(projectId: project.id, nodeId: item.node.id)
        }

        return outcome
    }

    private enum StartEvaluation {
        case succeeded
        case failed
    }

    @MainActor
    private static func evaluateAfterStart(
        processId: UUID,
        definition: ProcessDefinition,
        manager: ProcessManager
    ) -> StartEvaluation {
        switch manager.status(for: processId) {
        case .running:
            return .succeeded
        case .failed:
            return .failed
        case .stopped:
            if let code = manager.runningProcess(for: processId)?.exitCode {
                return code == 0 ? .succeeded : .failed
            }
            return (definition.type == .longRunning || definition.type == .folderWatch) ? .failed : .succeeded
        case .starting, .stopping:
            return .failed
        }
    }
}
