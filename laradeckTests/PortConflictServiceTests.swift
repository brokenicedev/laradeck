import XCTest
@testable import laradeck

final class PortConflictServiceTests: XCTestCase {
    func testExtractComposePortExpressionsFindsSailStyleDefaults() {
        let compose = """
        services:
          laravel.test:
            ports:
              - '${APP_PORT:-80}:80'
              - '${VITE_PORT:-5173}:${VITE_PORT:-5173}'
          mysql:
            ports:
              - '${FORWARD_DB_PORT:-3306}:3306'
        """

        let matches = PortConflictService.extractComposePortExpressions(from: compose)
        let byKey = Dictionary(uniqueKeysWithValues: matches.map { ($0.variable, $0.defaultPort) })
        XCTAssertEqual(byKey["APP_PORT"], 80)
        XCTAssertEqual(byKey["VITE_PORT"], 5173)
        XCTAssertEqual(byKey["FORWARD_DB_PORT"], 3306)
    }

    func testComposePortRequirementsPreferEnvOverrides() {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("laradeck-port-test-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let compose = """
        services:
          app:
            ports:
              - '${APP_PORT:-80}:80'
              - '${FORWARD_DB_PORT:-3306}:3306'
        """
        try! compose.write(to: temp.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        try! "APP_PORT=8081\nFORWARD_DB_PORT=3307\n"
            .write(to: temp.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let requirements = PortConflictService.composePortRequirements(
            projectPath: temp.path,
            env: PortConflictService.envMap(at: temp.path),
            isSail: false
        )
        let byKey = Dictionary(uniqueKeysWithValues: requirements.map { ($0.key, $0.port) })
        XCTAssertEqual(byKey["APP_PORT"], 8081)
        XCTAssertEqual(byKey["FORWARD_DB_PORT"], 3307)
        XCTAssertTrue(requirements.allSatisfy(\.isEnvWritable))
    }

    func testSuggestedEnvSnippetSkipsNonWritableProcessPorts() {
        let conflicts = [
            PortConflict(
                port: 8000,
                requirement: ProjectPortRequirement(
                    key: "process:serve",
                    label: "Web Server",
                    port: 8000,
                    isEnvWritable: false
                ),
                reason: "Already in use on this Mac"
            ),
            PortConflict(
                port: 80,
                requirement: ProjectPortRequirement(
                    key: "APP_PORT",
                    label: "App",
                    port: 80,
                    isEnvWritable: true
                ),
                reason: "Already in use on this Mac"
            ),
        ]
        var avoiding: Set<Int> = [80, 8000]
        let snippet = PortConflictService.suggestedEnvSnippet(for: conflicts, avoiding: &avoiding)
        XCTAssertTrue(snippet.contains("APP_PORT="))
        XCTAssertFalse(snippet.contains("process:"))
        if let line = snippet.split(separator: "\n").first,
           let value = line.split(separator: "=").last,
           let port = Int(value) {
            XCTAssertNotEqual(port, 80)
            XCTAssertNotEqual(port, 8000)
        } else {
            XCTFail("Expected APP_PORT suggestion")
        }
    }

    func testReportIgnoresPortsOwnedBySameProjectContainers() {
        let projectId = UUID()
        let otherId = UUID()
        let project = Project(
            id: projectId,
            name: "Alpha",
            path: "/tmp/alpha",
            environment: .sail,
            packageManager: .npm
        )
        let statuses: [UUID: [DockerServiceStatus]] = [
            projectId: [
                DockerServiceStatus(name: "mysql", state: "running", health: nil, ports: [3306], exitCode: nil),
            ],
            otherId: [
                DockerServiceStatus(name: "mysql", state: "running", health: nil, ports: [3307], exitCode: nil),
            ],
        ]

        // No filesystem compose — empty requirements → nil report.
        let report = PortConflictService.report(
            for: project,
            allProjects: [project],
            dockerStatuses: statuses,
            runningProcessPorts: [],
            includeComposePorts: true,
            includeProcessPorts: false
        )
        XCTAssertNil(report)
    }

    func testReportFlagsForeignDockerPortWhenRequirementPresent() {
        let projectId = UUID()
        let otherId = UUID()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("laradeck-port-foreign-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try! """
        services:
          mysql:
            ports:
              - '${FORWARD_DB_PORT:-3306}:3306'
        """.write(to: temp.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)

        let project = Project(
            id: projectId,
            name: "Alpha",
            path: temp.path,
            environment: .native,
            packageManager: .npm
        )
        let other = Project(
            id: otherId,
            name: "Beta",
            path: "/tmp/beta",
            environment: .sail,
            packageManager: .npm
        )
        let statuses: [UUID: [DockerServiceStatus]] = [
            otherId: [
                DockerServiceStatus(name: "mysql", state: "running", health: nil, ports: [3306], exitCode: nil),
            ],
        ]

        let report = PortConflictService.report(
            for: project,
            allProjects: [project, other],
            dockerStatuses: statuses,
            runningProcessPorts: [],
            includeComposePorts: true,
            includeProcessPorts: false
        )
        XCTAssertEqual(report?.conflicts.count, 1)
        XCTAssertEqual(report?.conflicts.first?.port, 3306)
        XCTAssertTrue(report?.conflicts.first?.reason.contains("Beta") == true)
        XCTAssertTrue(report?.suggestedEnvSnippet.contains("FORWARD_DB_PORT=") == true)
    }

    /// Sail apps that drop Redis/MySQL from compose (host Redis, shared DB) must not warn on 6379/3306.
    func testSailComposeWithoutRedisDoesNotRequireRedisPort() {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("laradeck-port-noredis-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try! """
        services:
          laravel.test:
            ports:
              - '${APP_PORT:-80}:80'
              - '${VITE_PORT:-5173}:${VITE_PORT:-5173}'
          gotenberg:
            ports:
              - '${GOTENBERG_PORT:-3100}:3000'
        """.write(to: temp.appendingPathComponent("compose.yaml"), atomically: true, encoding: .utf8)
        try! "APP_PORT=8001\nREDIS_PORT=6379\nREDIS_HOST=host.docker.internal\n"
            .write(to: temp.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let requirements = PortConflictService.composePortRequirements(
            projectPath: temp.path,
            env: PortConflictService.envMap(at: temp.path),
            isSail: true
        )
        let keys = Set(requirements.map(\.key))
        XCTAssertTrue(keys.contains("APP_PORT"))
        XCTAssertTrue(keys.contains("VITE_PORT"))
        XCTAssertTrue(keys.contains("GOTENBERG_PORT"))
        XCTAssertFalse(keys.contains("FORWARD_REDIS_PORT"), "must not assume Sail publishes Redis")
        XCTAssertFalse(keys.contains("FORWARD_DB_PORT"), "must not assume Sail publishes MySQL")
        XCTAssertFalse(keys.contains("REDIS_PORT"), "client REDIS_PORT is not a published host port")
    }
}
