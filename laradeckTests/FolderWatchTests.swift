import XCTest
@testable import laradeck

final class FolderWatchTests: XCTestCase {
    func testPathResolverAbsoluteAndRelative() {
        XCTAssertEqual(
            FolderWatchPathResolver.resolve("/tmp/nitrogen/dist", projectPath: "/apps/host"),
            "/tmp/nitrogen/dist"
        )
        XCTAssertEqual(
            FolderWatchPathResolver.resolve("vendor/pkg/dist", projectPath: "/apps/host"),
            "/apps/host/vendor/pkg/dist"
        )
        XCTAssertEqual(
            FolderWatchPathResolver.resolveAll(["", "  ", "a"], projectPath: "/p"),
            ["/p/a"]
        )
    }

    func testProcessDefinitionDecodesWithoutWatchFields() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "Serve",
          "kind": "serve",
          "type": "longRunning",
          "executable": "php",
          "arguments": ["artisan", "serve"]
        }
        """.data(using: .utf8)!

        let definition = try JSONDecoder().decode(ProcessDefinition.self, from: json)
        XCTAssertEqual(definition.watchPaths, [])
        XCTAssertEqual(definition.watchDebounceMs, 500)
        XCTAssertEqual(definition.type, .longRunning)
    }

    func testFolderWatchDefinitionRoundTrip() throws {
        let original = ProcessDefinition(
            name: "Nitrogen assets",
            kind: .folderWatch,
            type: .folderWatch,
            executable: ".",
            watchPaths: ["vendor/n/dist", "/abs/dist"],
            watchDebounceMs: 750
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProcessDefinition.self, from: data)
        XCTAssertEqual(decoded.type, .folderWatch)
        XCTAssertEqual(decoded.kind, .folderWatch)
        XCTAssertEqual(decoded.watchPaths, ["vendor/n/dist", "/abs/dist"])
        XCTAssertEqual(decoded.watchDebounceMs, 750)
        XCTAssertTrue(decoded.commandLine.contains("Watch"))
        XCTAssertTrue(decoded.commandLine.contains("750ms"))
    }

    func testFolderWatchHonorsOtherCommandsExclusionFromStartAll() {
        let otherGroupId = UUID()
        let watchInOther = ProcessDefinition(
            name: "Watch",
            kind: .folderWatch,
            type: .folderWatch,
            executable: ".",
            groupId: otherGroupId,
            watchPaths: ["dist"]
        )
        let watchInProcesses = ProcessDefinition(
            name: "Watch Processes",
            kind: .folderWatch,
            type: .folderWatch,
            executable: ".",
            watchPaths: ["dist"]
        )
        let project = Project(
            name: "Demo",
            path: "/tmp/demo",
            environment: .native,
            packageManager: .npm,
            processes: [watchInOther, watchInProcesses],
            processGroups: [ProcessGroup(id: otherGroupId, name: "Other commands", excludedFromStartAll: true)]
        )
        XCTAssertFalse(project.isIncludedInStartAll(watchInOther))
        XCTAssertTrue(project.isIncludedInStartAll(watchInProcesses))
        XCTAssertTrue(project.isIncludedInStopAll(watchInOther))
    }

    func testNestProcessDefinitionUnderFolderWatch() {
        let watchId = UUID()
        let publishId = UUID()
        var nodes = [StartupSequenceNode(kind: .process(watchId))]
        StartupSequence.nestProcessDefinition(publishId, underParentProcessId: watchId, in: &nodes)
        let watchNode = StartupSequence.nodeForProcessId(watchId, in: nodes)
        XCTAssertEqual(watchNode?.children.count, 1)
        if case .process(let id) = watchNode?.children.first?.kind {
            XCTAssertEqual(id, publishId)
        } else {
            XCTFail("Expected nested publish process")
        }
    }

    func testFileFingerprintIgnoresUnrelatedSiblingChanges() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("laradeck-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let manifest = dir.appendingPathComponent("manifest.json")
        let noise = dir.appendingPathComponent("chunk.js")
        try Data("{}".utf8).write(to: manifest)
        try Data("a".utf8).write(to: noise)

        XCTAssertEqual(
            FolderWatchPathResolver.classify(manifest.path),
            .file(directory: dir.path, file: manifest.path)
        )
        XCTAssertEqual(
            FolderWatchPathResolver.classify(dir.path),
            .directory(dir.path)
        )

        let before = FolderWatchPathResolver.fileFingerprint(for: manifest.path)
        try Data("bb".utf8).write(to: noise)
        let afterNoise = FolderWatchPathResolver.fileFingerprint(for: manifest.path)
        XCTAssertEqual(before.contentHash, afterNoise.contentHash)
        XCTAssertEqual(before.size, afterNoise.size)

        try Data(#"{"a":1}"#.utf8).write(to: manifest)
        let afterManifest = FolderWatchPathResolver.fileFingerprint(for: manifest.path)
        XCTAssertNotEqual(before.contentHash, afterManifest.contentHash)

        // Touch without content change must not look like a content change.
        let touched = FolderWatchPathResolver.fileFingerprint(for: manifest.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: manifest.path
        )
        let afterTouch = FolderWatchPathResolver.fileFingerprint(for: manifest.path)
        XCTAssertEqual(touched.contentHash, afterTouch.contentHash)
        XCTAssertEqual(touched.size, afterTouch.size)
    }

    func testNodeForProcessIdFindsNestedWatcher() {
        let watchId = UUID()
        let childId = UUID()
        let nodes = [
            StartupSequenceNode(
                kind: .process(watchId),
                children: [StartupSequenceNode(kind: .process(childId))]
            )
        ]
        let found = StartupSequence.nodeForProcessId(watchId, in: nodes)
        XCTAssertEqual(found?.children.count, 1)
        if case .process(let id) = found?.children.first?.kind {
            XCTAssertEqual(id, childId)
        } else {
            XCTFail("Expected nested process child")
        }
        XCTAssertNil(StartupSequence.nodeForProcessId(UUID(), in: nodes))
    }

    /// Folder-watch nested children must run even when they live in Other commands and use the
    /// sheet default type (longRunning) — previously Start All exclusion skipped them silently.
    @MainActor
    func testFolderWatchFiresOtherCommandsLongRunningChild() async {
        _ = await RuntimeResolver.shared.loginShellEnvironment()

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("laradeck-watch-fire-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let otherGroupId = UUID()
        let watch = ProcessDefinition(
            name: "Watch",
            kind: .folderWatch,
            type: .folderWatch,
            executable: ".",
            groupId: otherGroupId,
            watchPaths: [dir.path],
            watchDebounceMs: 50
        )
        let child = ProcessDefinition(
            name: "Publish",
            kind: .custom,
            type: .longRunning,
            executable: "/bin/sleep",
            arguments: ["2"],
            groupId: otherGroupId
        )
        let project = Project(
            name: "Demo",
            path: dir.path,
            environment: .native,
            packageManager: .npm,
            processes: [watch, child],
            processGroups: [ProcessGroup(id: otherGroupId, name: "Other commands", excludedFromStartAll: true)],
            startupSequence: [
                StartupSequenceNode(
                    kind: .process(watch.id),
                    children: [StartupSequenceNode(kind: .process(child.id))]
                )
            ]
        )

        XCTAssertFalse(project.isIncludedInStartAll(child), "precondition: child is excluded from Start All")

        let manager = ProcessManager(notificationManager: NotificationManager())
        manager.start(watch, in: project, notify: false, armAttachedChildren: false)
        await manager.waitUntilStarted(watch.id)
        XCTAssertEqual(manager.status(for: watch.id), .running)

        manager.fireWatcherChildren(watcherId: watch.id, project: project)

        // Child used to be skipped instantly; now it must actually arm.
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(manager.status(for: child.id), .running, "nested Other longRunning child must run on watch fire")

        manager.stop(child, in: project, notify: false)
        manager.stop(watch, in: project, notify: false)
        await manager.waitForCompletion(child.id)
        await manager.waitForCompletion(watch.id)
    }
}
