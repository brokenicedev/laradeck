import XCTest
@testable import laradeck

final class ProjectTests: XCTestCase {
    func testIsIncludedInStartAllExcludesShortcutsAndOtherCommandsGroup() {
        let otherGroupId = UUID()
        var project = Project(
            name: "Demo",
            path: "/tmp/demo",
            environment: .native,
            packageManager: .npm,
            processes: [
                ProcessDefinition(name: "Serve", kind: .serve, executable: "php", arguments: ["artisan", "serve"]),
                ProcessDefinition(name: "Migrate", kind: .custom, type: .oneShot, executable: "php", arguments: ["artisan", "migrate"]),
                ProcessDefinition(name: "Clear", kind: .custom, type: .shortcut, executable: "php", arguments: ["artisan", "optimize:clear"]),
                ProcessDefinition(name: "Tinker", kind: .custom, executable: "php", arguments: ["artisan", "tinker"], groupId: otherGroupId),
            ],
            processGroups: [ProcessGroup(id: otherGroupId, name: "Other commands", excludedFromStartAll: true)]
        )

        XCTAssertTrue(project.isIncludedInStartAll(project.processes[0]))
        XCTAssertTrue(project.isIncludedInStartAll(project.processes[1]))
        XCTAssertFalse(project.isIncludedInStartAll(project.processes[2]))
        XCTAssertFalse(project.isIncludedInStartAll(project.processes[3]))

        // Stop All still covers Other commands (and Start All members).
        XCTAssertTrue(project.isIncludedInStopAll(project.processes[0]))
        XCTAssertTrue(project.isIncludedInStopAll(project.processes[3]))
        XCTAssertFalse(project.isIncludedInStopAll(project.processes[2])) // shortcut outside Other
    }

    func testSortedByStartOrderFollowsStartupSequence() {
        let serveId = UUID()
        let queueId = UUID()
        var project = Project(
            name: "Demo",
            path: "/tmp/demo",
            environment: .native,
            packageManager: .npm,
            processes: [
                ProcessDefinition(id: queueId, name: "Queue", kind: .queueWorker, executable: "php", arguments: ["artisan", "queue:work"]),
                ProcessDefinition(id: serveId, name: "Serve", kind: .serve, executable: "php", arguments: ["artisan", "serve"]),
            ],
            startupSequence: [
                StartupSequenceNode(kind: .process(serveId)),
                StartupSequenceNode(kind: .process(queueId)),
            ]
        )

        let sorted = project.sortedByStartOrder(project.processes)
        XCTAssertEqual(sorted.map(\.id), [serveId, queueId])
    }
}
