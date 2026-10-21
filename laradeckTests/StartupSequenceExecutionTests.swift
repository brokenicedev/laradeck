import XCTest
@testable import laradeck

/// End-to-end coverage of Start All / manual attached starts: real (but tiny) processes through
/// `ProcessManager` and `StartupSequenceRunner`. Same-level siblings with no pause arm together;
/// pauses only block what follows at that level. Nested children do not hold back peer siblings.
@MainActor
final class StartupSequenceExecutionTests: XCTestCase {
    override func setUp() async throws {
        // `RuntimeResolver.shared` lazily spawns a real login shell (`zsh -ilc env`) to resolve
        // PATH etc. the first time any process launches — that can take a couple of seconds and
        // would otherwise skew every timing assertion below. Warm the cache up front instead.
        _ = await RuntimeResolver.shared.loginShellEnvironment()
    }

    private func makeProcess(_ name: String, seconds: Double = 5) -> ProcessDefinition {
        ProcessDefinition(name: name, kind: .custom, type: .longRunning, executable: "/bin/sleep", arguments: ["\(seconds)"])
    }

    private func makeProject(processes: [ProcessDefinition], sequence: [StartupSequenceNode]) -> Project {
        Project(
            name: "Demo",
            path: NSTemporaryDirectory(),
            environment: .native,
            packageManager: .npm,
            processes: processes,
            startupSequence: sequence
        )
    }

    private func stopAll(_ manager: ProcessManager, _ project: Project) async {
        for definition in project.processes {
            manager.stop(definition, in: project)
        }
        for definition in project.processes {
            await manager.waitForCompletion(definition.id)
        }
    }

    // MARK: - Flat top-level list

    func testFlatListPauseBlocksNextProcess() async {
        let a = makeProcess("A")
        let b = makeProcess("B")
        let project = makeProject(
            processes: [a, b],
            sequence: [
                StartupSequenceNode(kind: .process(a.id)),
                StartupSequenceNode(kind: .delay(seconds: 1)),
                StartupSequenceNode(kind: .process(b.id)),
            ]
        )
        let manager = ProcessManager(notificationManager: NotificationManager())

        let run = Task {
            _ = await StartupSequenceRunner.runSequence(project.effectiveStartupSequence, project: project, manager: manager, notify: false)
        }

        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(manager.status(for: a.id), .running, "A should start immediately")
        XCTAssertEqual(manager.status(for: b.id), .stopped, "B must not start before A's pause")

        // A is long-running, so the runner settles ~900ms before even reaching the pause node;
        // this checkpoint lands mid-pause either way.
        try? await Task.sleep(for: .milliseconds(1300))
        XCTAssertEqual(manager.status(for: b.id), .stopped, "B must still be waiting mid-pause")

        try? await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(manager.status(for: b.id), .running, "B must start once the pause elapses")

        _ = await run.value
        await stopAll(manager, project)
    }

    func testFlatListWithNoPauseStartsImmediately() async {
        let a = makeProcess("A")
        let b = makeProcess("B")
        let project = makeProject(
            processes: [a, b],
            sequence: [
                StartupSequenceNode(kind: .process(a.id)),
                StartupSequenceNode(kind: .process(b.id)),
            ]
        )
        let manager = ProcessManager(notificationManager: NotificationManager())

        let run = Task {
            _ = await StartupSequenceRunner.runSequence(project.effectiveStartupSequence, project: project, manager: manager, notify: false)
        }

        // No pause between A and B — both must arm in the same burst (not after A's settle).
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(manager.status(for: a.id), .running)
        XCTAssertEqual(manager.status(for: b.id), .running, "same-level siblings with no pause must start together")

        _ = await run.value
        await stopAll(manager, project)
    }

    // MARK: - Attached children (nested under a persistent parent)

    func testAttachedChildrenWithNoPauseArmTogether() async {
        let parent = makeProcess("Parent")
        let c1 = makeProcess("Child1")
        let c2 = makeProcess("Child2")
        let project = makeProject(
            processes: [parent, c1, c2],
            sequence: [
                StartupSequenceNode(
                    kind: .process(parent.id),
                    children: [
                        StartupSequenceNode(kind: .process(c1.id)),
                        StartupSequenceNode(kind: .process(c2.id)),
                    ]
                ),
            ]
        )
        let manager = ProcessManager(notificationManager: NotificationManager())

        manager.start(parent, in: project, notify: false)

        // Parent settles for ~900ms before arming children; give it margin, then both children
        // should already be up (no pause between them, so no reason to run one after the other).
        try? await Task.sleep(for: .milliseconds(1400))
        XCTAssertEqual(manager.status(for: parent.id), .running)
        XCTAssertEqual(manager.status(for: c1.id), .running, "first child should have armed with the parent")
        XCTAssertEqual(manager.status(for: c2.id), .running, "second child should have armed at the same time as the first")

        await stopAll(manager, project)
    }

    func testAttachedChildrenPauseBlocksLaterSibling() async {
        let parent = makeProcess("Parent")
        let c1 = makeProcess("Child1")
        let c2 = makeProcess("Child2")
        let project = makeProject(
            processes: [parent, c1, c2],
            sequence: [
                StartupSequenceNode(
                    kind: .process(parent.id),
                    children: [
                        StartupSequenceNode(kind: .process(c1.id)),
                        StartupSequenceNode(kind: .delay(seconds: 1)),
                        StartupSequenceNode(kind: .process(c2.id)),
                    ]
                ),
            ]
        )
        let manager = ProcessManager(notificationManager: NotificationManager())

        manager.start(parent, in: project, notify: false, armAttachedChildren: true)

        // Parent settles (~900ms) then arms Child1 immediately; Child2 sits behind the pause.
        try? await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(manager.status(for: parent.id), .running)
        XCTAssertEqual(manager.status(for: c1.id), .running, "first child should have armed right after the parent settled")
        XCTAssertEqual(manager.status(for: c2.id), .stopped, "second child must wait for the pause between siblings")

        // Still mid-pause.
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(manager.status(for: c2.id), .stopped, "second child must still be waiting mid-pause")

        // Pause elapsed.
        try? await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(manager.status(for: c2.id), .running, "second child must start once the pause between siblings elapses")

        await stopAll(manager, project)
    }

    /// Same-level root siblings arm together even while one of them still has nested pauses.
    func testStartAllSameLevelArmsTogetherDespiteNestedPause() async {
        let parent = makeProcess("Parent")
        let child = makeProcess("Child")
        let sibling = makeProcess("Sibling")
        let project = makeProject(
            processes: [parent, child, sibling],
            sequence: [
                StartupSequenceNode(
                    kind: .process(parent.id),
                    children: [
                        StartupSequenceNode(kind: .process(child.id)),
                        StartupSequenceNode(kind: .delay(seconds: 1)),
                    ]
                ),
                StartupSequenceNode(kind: .process(sibling.id)),
            ]
        )
        let manager = ProcessManager(notificationManager: NotificationManager())

        let run = Task {
            _ = await StartupSequenceRunner.runSequence(
                project.effectiveStartupSequence,
                project: project,
                manager: manager,
                notify: false
            )
        }

        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(manager.status(for: parent.id), .running)
        XCTAssertEqual(manager.status(for: sibling.id), .running, "same-level sibling must arm with the parent")

        // Nested child still respects its own pause under the parent.
        try? await Task.sleep(for: .milliseconds(2000))
        XCTAssertEqual(manager.status(for: child.id), .running, "nested child starts after parent settles")

        _ = await run.value
        await stopAll(manager, project)
    }

    /// Start All must honor root pauses and nested pauses; nested pauses never block root peers.
    func testStartAllNestedPauseBlocksLaterChild() async {
        let a = makeProcess("A")
        let b = makeProcess("B")
        let c1 = makeProcess("Child1")
        let c2 = makeProcess("Child2")
        let project = makeProject(
            processes: [a, b, c1, c2],
            sequence: [
                StartupSequenceNode(kind: .process(a.id)),
                StartupSequenceNode(kind: .delay(seconds: 1)),
                StartupSequenceNode(
                    kind: .process(b.id),
                    children: [
                        StartupSequenceNode(kind: .process(c1.id)),
                        StartupSequenceNode(kind: .delay(seconds: 1)),
                        StartupSequenceNode(kind: .process(c2.id)),
                    ]
                ),
            ]
        )
        let manager = ProcessManager(notificationManager: NotificationManager())

        let run = Task {
            _ = await StartupSequenceRunner.runSequence(
                project.effectiveStartupSequence,
                project: project,
                manager: manager,
                notify: false
            )
        }

        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(manager.status(for: a.id), .running)
        XCTAssertEqual(manager.status(for: b.id), .stopped, "B must wait for the root pause after A")

        try? await Task.sleep(for: .milliseconds(1400))
        XCTAssertEqual(manager.status(for: b.id), .stopped, "B must still be waiting mid root-pause")

        try? await Task.sleep(for: .milliseconds(2000))
        XCTAssertEqual(manager.status(for: b.id), .running)
        XCTAssertEqual(manager.status(for: c1.id), .running)
        XCTAssertEqual(manager.status(for: c2.id), .stopped, "C2 must wait for nested pause")

        try? await Task.sleep(for: .milliseconds(2000))
        XCTAssertEqual(manager.status(for: c2.id), .running, "C2 must start after nested pause")

        _ = await run.value
        await stopAll(manager, project)
    }
}
