import XCTest
@testable import laradeck

final class StartupSequenceTests: XCTestCase {
    func testExecutionOrderVisitsSiblingsBeforeNestedChildren() {
        let serveId = UUID()
        let queueId = UUID()
        let viteId = UUID()
        let nodes: [StartupSequenceNode] = [
            StartupSequenceNode(
                kind: .process(serveId),
                children: [StartupSequenceNode(kind: .process(viteId))]
            ),
            StartupSequenceNode(kind: .process(queueId)),
        ]

        let order = StartupSequence.executionOrder(nodes)
        let processOrder = order.compactMap { node -> UUID? in
            if case .process(let id) = node.kind { return id }
            return nil
        }
        XCTAssertEqual(processOrder, [serveId, queueId, viteId])
    }

    func testParentProcessIdFindsTheProcessAStepIsAttachedUnder() {
        let queueId = UUID()
        let watchId = UUID()
        let publishId = UUID()
        let nodes: [StartupSequenceNode] = [
            StartupSequenceNode(kind: .process(queueId)),
            StartupSequenceNode(
                kind: .process(watchId),
                children: [StartupSequenceNode(kind: .process(publishId))]
            ),
        ]
        XCTAssertEqual(StartupSequence.parentProcessId(of: publishId, in: nodes), watchId)
        XCTAssertNil(StartupSequence.parentProcessId(of: watchId, in: nodes))
        XCTAssertNil(StartupSequence.parentProcessId(of: UUID(), in: nodes))
    }

    func testSyncRemovesStaleProcessesAndAppendsNewOnes() {
        let serveId = UUID()
        let staleId = UUID()
        let horizonId = UUID()
        var sequence = [
            StartupSequenceNode(kind: .process(serveId)),
            StartupSequenceNode(kind: .process(staleId)),
        ]
        let project = Project(
            name: "Demo",
            path: "/tmp/demo",
            environment: .native,
            packageManager: .npm,
            processes: [
                ProcessDefinition(id: serveId, name: "Serve", kind: .serve, executable: "php", arguments: ["artisan", "serve"]),
                ProcessDefinition(id: horizonId, name: "Horizon", kind: .horizon, executable: "php", arguments: ["artisan", "horizon"]),
            ]
        )

        StartupSequence.sync(into: &sequence, project: project)
        XCTAssertEqual(StartupSequence.collectProcessIds(sequence), [serveId, horizonId])
    }

    func testApplyFlatOrderPreservesDragOrder() {
        let firstId = UUID()
        let secondId = UUID()
        let nodes = StartupSequence.applyFlatOrder([secondId, firstId])
        XCTAssertEqual(StartupSequence.collectProcessIds(nodes), [secondId, firstId])
    }

    func testInsertPauseAfterNode() {
        let serveId = UUID()
        var nodes = [StartupSequenceNode(kind: .process(serveId))]
        StartupSequence.insertPause(afterNodeId: nodes[0].id, seconds: 5, in: &nodes)
        XCTAssertEqual(nodes.count, 2)
        if case .delay(let seconds) = nodes[1].kind {
            XCTAssertEqual(seconds, 5)
        } else {
            XCTFail("Expected delay node")
        }
    }

    func testFilteredTreeKeepsSectionNestingAndPromotesCrossSectionChildren() {
        let serveId = UUID()
        let watchId = UUID()
        let publishId = UUID()
        let nodes: [StartupSequenceNode] = [
            StartupSequenceNode(kind: .delay(seconds: 2)),
            StartupSequenceNode(
                kind: .process(serveId),
                children: [
                    StartupSequenceNode(
                        kind: .process(watchId),
                        children: [StartupSequenceNode(kind: .process(publishId))]
                    )
                ]
            ),
        ]

        let processesOnly = StartupSequence.filteredTree(
            nodes,
            allowing: [serveId],
            includeRootDelays: true
        )
        XCTAssertEqual(processesOnly.count, 2)
        if case .delay = processesOnly[0].kind {} else { XCTFail("Expected root delay") }
        if case .process(let id) = processesOnly[1].kind {
            XCTAssertEqual(id, serveId)
            XCTAssertTrue(processesOnly[1].children.isEmpty)
        } else {
            XCTFail("Expected serve")
        }

        let otherOnly = StartupSequence.filteredTree(
            nodes,
            allowing: [watchId, publishId],
            includeRootDelays: false
        )
        XCTAssertEqual(otherOnly.count, 1)
        if case .process(let id) = otherOnly[0].kind {
            XCTAssertEqual(id, watchId)
            XCTAssertEqual(otherOnly[0].children.count, 1)
            if case .process(let childId) = otherOnly[0].children[0].kind {
                XCTAssertEqual(childId, publishId)
            } else {
                XCTFail("Expected nested publish")
            }
        } else {
            XCTFail("Expected watch promoted to root")
        }
    }

    /// A pause nested under a process only makes sense in that process's own subtree — filtering
    /// it into a section that excludes that process (e.g. Processes' pause showing in Other
    /// commands) used to leak it because promoted children kept delay nodes unconditionally.
    func testFilteredTreeDropsPauseWhenOwningProcessIsExcluded() {
        let webServerId = UUID()
        let queueWorkerId = UUID()
        let otherCommandId = UUID()
        let nodes: [StartupSequenceNode] = [
            StartupSequenceNode(
                kind: .process(webServerId),
                children: [
                    StartupSequenceNode(kind: .delay(seconds: 3)),
                    StartupSequenceNode(kind: .process(queueWorkerId)),
                ]
            ),
        ]

        let otherCommandsOnly = StartupSequence.filteredTree(
            nodes,
            allowing: [otherCommandId],
            includeRootDelays: false
        )

        XCTAssertTrue(otherCommandsOnly.isEmpty, "Pause and process nested under an excluded parent must not leak into another section")
    }

    func testNestEarlierSiblingUnderLaterSibling() {
        let watchId = UUID()
        let publishId = UUID()
        let watchNode = StartupSequenceNode(kind: .process(watchId))
        let publishNode = StartupSequenceNode(kind: .process(publishId))
        var nodes = [watchNode, publishNode]

        StartupSequence.nestNode(withId: watchNode.id, underNodeId: publishNode.id, in: &nodes)

        XCTAssertEqual(nodes.count, 1)
        if case .process(let id) = nodes[0].kind {
            XCTAssertEqual(id, publishId)
            XCTAssertEqual(nodes[0].children.count, 1)
            if case .process(let childId) = nodes[0].children[0].kind {
                XCTAssertEqual(childId, watchId)
            } else {
                XCTFail("Expected nested watch")
            }
        } else {
            XCTFail("Expected publish as parent")
        }
    }

    func testSyncIncludesOtherCommandsForNesting() {
        let otherGroupId = UUID()
        let watchId = UUID()
        let publishId = UUID()
        var sequence: [StartupSequenceNode] = []
        let project = Project(
            name: "Demo",
            path: "/tmp/demo",
            environment: .native,
            packageManager: .npm,
            processes: [
                ProcessDefinition(
                    id: watchId,
                    name: "Watch",
                    kind: .folderWatch,
                    type: .folderWatch,
                    executable: ".",
                    groupId: otherGroupId,
                    watchPaths: ["dist"]
                ),
                ProcessDefinition(
                    id: publishId,
                    name: "Publish",
                    kind: .custom,
                    type: .oneShot,
                    executable: "php",
                    arguments: ["artisan", "nitrogen:publish"],
                    groupId: otherGroupId
                ),
            ],
            processGroups: [ProcessGroup(id: otherGroupId, name: "Other commands", excludedFromStartAll: true)]
        )

        StartupSequence.sync(into: &sequence, project: project)
        let ids = Set(StartupSequence.collectProcessIds(sequence))
        XCTAssertEqual(ids, [watchId, publishId])
        XCTAssertTrue(project.isOtherCommand(project.processes[1]))
        XCTAssertFalse(project.isIncludedInStartAll(project.processes[1]))
    }
}
