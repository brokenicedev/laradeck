import DBEngineKit
import XCTest
@testable import laradeck

final class ProjectDatabaseLinkTests: XCTestCase {
    func testPostgresWithDefaultPort() {
        let reqs = ProjectDatabaseLink.requirements(env: ["DB_CONNECTION": "pgsql", "DB_HOST": "127.0.0.1"])
        XCTAssertEqual(reqs, [ProjectDatabaseRequirement(kind: .postgresql, port: 5432, envKey: "DB_PORT", database: "laravel")])
    }

    func testMariaDBMapsToMySQLWithCustomPort() {
        let reqs = ProjectDatabaseLink.requirements(env: ["DB_CONNECTION": "mariadb", "DB_PORT": "3307"])
        XCTAssertEqual(reqs.first?.kind, .mysql)
        XCTAssertEqual(reqs.first?.port, 3307)
    }

    func testSQLiteAndRemoteHostsNeedNothing() {
        XCTAssertTrue(ProjectDatabaseLink.requirements(env: ["DB_CONNECTION": "sqlite"]).isEmpty)
        XCTAssertTrue(ProjectDatabaseLink.requirements(env: ["DB_CONNECTION": "mysql", "DB_HOST": "db.example.com"]).isEmpty)
    }

    func testRedisOnlyWhenADriverUsesIt() {
        XCTAssertTrue(ProjectDatabaseLink.requirements(env: ["REDIS_HOST": "127.0.0.1"]).isEmpty)
        let reqs = ProjectDatabaseLink.requirements(env: ["QUEUE_CONNECTION": "redis", "REDIS_PORT": "6380"])
        XCTAssertEqual(reqs, [ProjectDatabaseRequirement(kind: .redis, port: 6380, envKey: "REDIS_PORT")])
    }

    func testServiceMatchNeedsSameEngineAndPort() {
        func service(_ kind: EngineKind, _ port: Int) -> Service {
            Service(name: "\(kind)", kind: kind, version: "1", binariesPath: "/x", dataPath: "/y", port: port)
        }
        let services = [service(.mysql, 5432), service(.postgresql, 5433), service(.postgresql, 5432)]
        let match = ProjectDatabaseLink.service(
            for: ProjectDatabaseRequirement(kind: .postgresql, port: 5432, envKey: "DB_PORT"),
            in: services
        )
        XCTAssertEqual(match?.id, services[2].id)
    }

    func testDockerProjectsLinkOnlyThroughHostDockerInternal() {
        let viaHost = ProjectDatabaseLink.requirements(
            env: ["DB_CONNECTION": "mysql", "DB_HOST": "host.docker.internal", "DB_PORT": "3306", "DB_DATABASE": "shop"],
            inDocker: true
        )
        XCTAssertEqual(viaHost, [ProjectDatabaseRequirement(kind: .mysql, port: 3306, envKey: "DB_PORT", database: "shop")])

        // Sail's own container, or 127.0.0.1 inside the container: not the Mac.
        XCTAssertTrue(ProjectDatabaseLink.requirements(env: ["DB_CONNECTION": "mysql", "DB_HOST": "mysql"], inDocker: true).isEmpty)
        XCTAssertTrue(ProjectDatabaseLink.requirements(env: ["DB_CONNECTION": "pgsql", "DB_HOST": "127.0.0.1"], inDocker: true).isEmpty)

        let redis = ProjectDatabaseLink.requirements(
            env: ["CACHE_STORE": "redis", "REDIS_HOST": "host.docker.internal"], inDocker: true
        )
        XCTAssertEqual(redis.first?.kind, .redis)
    }

    func testNativeProjectAcceptsHostDockerInternalToo() {
        let reqs = ProjectDatabaseLink.requirements(env: ["DB_CONNECTION": "pgsql", "DB_HOST": "host.docker.internal"])
        XCTAssertEqual(reqs.first?.kind, .postgresql)
    }

    func testDockerServiceNamesMapToEngines() {
        XCTAssertEqual(DockerDatabase.engine(forService: "pgsql"), .postgresql)
        XCTAssertEqual(DockerDatabase.engine(forService: "mariadb"), .mysql)
        XCTAssertEqual(DockerDatabase.engine(forService: "mysql"), .mysql)
        XCTAssertEqual(DockerDatabase.engine(forService: "valkey"), .redis)
        XCTAssertNil(DockerDatabase.engine(forService: "laravel.test"))
        XCTAssertNil(DockerDatabase.engine(forService: "mailpit"))
    }
}
