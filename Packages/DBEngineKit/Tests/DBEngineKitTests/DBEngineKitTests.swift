@testable import DBEngineKit
import XCTest

final class DBEngineKitTests: XCTestCase {
    var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dbengine-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func sample(_ kind: EngineKind, port: Int = 0) -> Service {
        let id = UUID()
        let paths = Paths(root: root)
        return Service(id: id, name: "Test & <db>", kind: kind, version: "1.0",
                       binariesPath: "/opt/engines/\(kind.rawValue)",
                       dataPath: paths.dataPath(for: kind, id: id).path,
                       port: port == 0 ? kind.defaultPort : port)
    }

    func testPlistIsValidAndEscaped() throws {
        let s = sample(.postgresql)
        let data = try Launchd.plist(label: s.launchdLabel(prefix: "x.y"),
                                     arguments: s.kind.serverArguments(s),
                                     workingDirectory: URL(fileURLWithPath: "/tmp/a & <b>"),
                                     logFile: s.kind.logFile(s))
        let dict = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(dict["Label"] as? String, "x.y.postgres-\(s.id.uuidString)")
        XCTAssertEqual(dict["WorkingDirectory"] as? String, "/tmp/a & <b>")
        XCTAssertEqual(dict["RunAtLoad"] as? Bool, true)
        let args = try XCTUnwrap(dict["ProgramArguments"] as? [String])
        XCTAssertEqual(args.first, "/opt/engines/postgresql/bin/postgres")
        XCTAssertTrue(args.contains("5432"))
    }

    func testServerArguments() {
        let mysql = sample(.mysql, port: 3310)
        let a = mysql.kind.serverArguments(mysql)
        XCTAssertTrue(a.contains("--port=3310"))
        XCTAssertTrue(a.contains("--socket=/tmp/mysql_3310.sock"))
        let redis = sample(.redis, port: 6390)
        XCTAssertEqual(Array(redis.kind.serverArguments(redis)[1...2]), ["--port", "6390"])
    }

    func testBindAddressFollowsNetworkShare() {
        var pg = sample(.postgresql)
        XCTAssertTrue(pg.kind.serverArguments(pg).contains("listen_addresses=localhost"))
        pg.networkShare = NetworkShare.generate()
        XCTAssertTrue(pg.kind.serverArguments(pg).contains("listen_addresses=*"))

        var mysql = sample(.mysql)
        XCTAssertTrue(mysql.kind.serverArguments(mysql).contains("--bind-address=127.0.0.1"))
        mysql.networkShare = NetworkShare.generate()
        XCTAssertTrue(mysql.kind.serverArguments(mysql).contains("--bind-address=*"))
        XCTAssertFalse(EngineKind.redis.supportsNetworkShare)
    }

    func testGeneratedPasswordNeedsNoQuoting() {
        let share = NetworkShare.generate()
        XCTAssertEqual(share.user, "laradeck_share")
        XCTAssertEqual(share.password.count, 24)
        XCTAssertTrue(share.password.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
        XCTAssertNotEqual(share.password, NetworkShare.generate().password)
    }

    func testShareSQL() {
        let share = NetworkShare(user: "laradeck_share", password: "abc123")
        let mysql = EngineKind.mysql.shareUserSQL(share)
        XCTAssertEqual(mysql.first, "CREATE USER IF NOT EXISTS 'laradeck_share'@'%' IDENTIFIED BY 'abc123'")
        XCTAssertTrue(mysql.contains("GRANT ALL PRIVILEGES ON *.* TO 'laradeck_share'@'%'"))
        XCTAssertTrue(EngineKind.postgresql.shareUserSQL(share).last?.contains("PASSWORD 'abc123'") == true)
        XCTAssertEqual(EngineKind.postgresql.dropShareUserSQL(share), ["DROP ROLE IF EXISTS \"laradeck_share\""])
        XCTAssertEqual(EngineKind.redis.shareUserSQL(share), [])
    }

    func testHbaBlockIsIdempotentAndRemovable() {
        let original = "local all all trust\nhost all all 127.0.0.1/32 trust\n"
        let once = NetworkShare.addingShareBlock(to: original, user: "u")
        let twice = NetworkShare.addingShareBlock(to: once, user: "u")
        XCTAssertEqual(once, twice)
        XCTAssertTrue(once.hasPrefix(original))
        XCTAssertTrue(once.contains("host    all    u    0.0.0.0/0    scram-sha-256"))
        XCTAssertEqual(NetworkShare.removingShareBlock(from: once), original)
        XCTAssertEqual(NetworkShare.removingShareBlock(from: original), original)
    }

    func testServiceWithoutShareStillDecodes() throws {
        let s = sample(.mysql)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
        json["networkShare"] = nil
        let decoded = try JSONDecoder().decode(Service.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.networkShare)
        XCTAssertEqual(decoded.id, s.id)
    }

    func testCreateDatabaseQuoting() {
        XCTAssertEqual(EngineKind.postgresql.createDatabaseSQL("a\"b"), "CREATE DATABASE \"a\"\"b\"")
        XCTAssertEqual(EngineKind.mysql.createDatabaseSQL("a`b")?.hasPrefix("CREATE DATABASE `a``b`"), true)
        XCTAssertNil(EngineKind.redis.createDatabaseSQL("x"))
    }

    func testConnectionURLs() {
        XCTAssertEqual(EngineKind.postgresql.connectionURL(port: 5432, name: "pg"),
                       "postgresql://postgres@127.0.0.1:5432/postgres?name=pg")
        XCTAssertEqual(EngineKind.redis.connectionURL(port: 6379, name: "r"), "redis://127.0.0.1:6379?name=r")
    }

    func testStoreRoundTripAndBackupRecovery() throws {
        let store = ServiceStore(paths: Paths(root: root))
        let s = sample(.redis)
        try store.update { $0.append(s) }
        try store.update { $0[0].port = 7000 } // second write creates a backup
        XCTAssertEqual(try store.load().first?.port, 7000)

        // Corrupt the main file: load falls back to the backup copy.
        try Data("garbage".utf8).write(to: Paths(root: root).serviceList)
        XCTAssertEqual(try store.load().first?.id, s.id)
    }

    func testFindByPrefixAndName() throws {
        let m = ServiceManager(paths: Paths(root: root))
        let s = sample(.redis)
        try m.store.update { $0.append(s) }
        XCTAssertEqual(try m.find(String(s.id.uuidString.prefix(6))).id, s.id)
        XCTAssertEqual(try m.find("test & <DB>").id, s.id)
        XCTAssertThrowsError(try m.find("nope"))
    }
}

/// Real servers from Homebrew. Opt-in: `DBENGINE_E2E=1 swift test --filter EndToEnd`.
final class EndToEndTests: XCTestCase {
    func testHomebrewEnginesStartRestartAndStop() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DBENGINE_E2E"] == "1", "set DBENGINE_E2E=1")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dbengine-e2e-\(UUID().uuidString)")
        let m = ServiceManager(paths: Paths(root: root, label: "it.brokenice.laradeck.db.e2e"))
        defer { try? FileManager.default.removeItem(at: root) }

        var ports = 47_000
        for kind in EngineKind.allCases {
            guard let formula = Homebrew.installed(kind).first?.formula else {
                print("skip \(kind): no Homebrew formula installed")
                continue
            }
            ports += 1
            let s = try await m.create(kind: kind, formula: formula, port: ports)
            defer { try? m.delete(s, keepData: true) } // root folder is removed below; keep the Trash clean
            print("\(kind): \(s.version) from \(s.binariesPath) on \(s.port)")

            try await m.start(s)
            guard case let .running(pid) = m.status(of: s) else { return XCTFail("\(kind) not running") }

            // launchd restarts a crashed server (KeepAlive.SuccessfulExit = false).
            kill(pid, SIGKILL)
            var newPid: Int32?
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if case let .running(p) = m.status(of: s), p != pid { newPid = p; break }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            XCTAssertNotNil(newPid, "\(kind) not restarted after SIGKILL")
            let listening = await Port.waitUntilListening(s.port, timeout: 30)
            XCTAssertTrue(listening, "\(kind) not accepting connections after restart")

            if kind != .redis {
                let name = "laradeck e2e \"quoted\""
                XCTAssertFalse(try m.databaseNames(in: s).contains(name))
                try m.createDatabase(name, in: s)
                XCTAssertTrue(try m.databaseNames(in: s).contains(name), "\(kind): created database not listed")
            }

            try m.stop(s)
            XCTAssertEqual(m.status(of: s), .stopped)
            XCTAssertFalse(Port.isListening(s.port))
        }
    }

    /// Share on, connect through the LAN address with the share password, share off.
    func testNetworkShare() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DBENGINE_E2E"] == "1", "set DBENGINE_E2E=1")
        let ip = (try? Shell.run(["/usr/sbin/ipconfig", "getifaddr", "en0"], check: false).output)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try XCTSkipIf(ip.isEmpty, "no LAN address on en0")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dbengine-share-\(UUID().uuidString)")
        let m = ServiceManager(paths: Paths(root: root, label: "it.brokenice.laradeck.db.e2e"))
        defer { try? FileManager.default.removeItem(at: root) }

        var port = 47_100
        for kind in [EngineKind.postgresql, .mysql] {
            guard let formula = Homebrew.installed(kind).first?.formula else { continue }
            port += 1
            let s = try await m.create(kind: kind, formula: formula, port: port)
            defer { try? m.delete(s, keepData: true) }
            try await m.start(s)

            let shared = try await m.enableNetworkShare(s)
            let share = try XCTUnwrap(shared.networkShare)
            XCTAssertTrue(m.status(of: shared).isRunning)

            func remote(user: String, password: String, database: String? = nil,
                        sql: String = "SELECT 1") -> Bool {
                let bin = shared.binaryURL
                let cmd: [String]
                var env = kind.environment
                switch kind {
                case .postgresql:
                    env["PGPASSWORD"] = password
                    cmd = [bin.appendingPathComponent("psql").path, "-h", ip, "-p", String(shared.port),
                           "-U", user, "-d", database ?? "postgres", "-w", "-X", "-t",
                           "-v", "ON_ERROR_STOP=1", "-c", sql]
                default:
                    env["MYSQL_PWD"] = password
                    cmd = [bin.appendingPathComponent("mysql").path, "-h", ip, "-P", String(shared.port),
                           "-u", user, "--get-server-public-key"] + (database.map { [$0] } ?? []) + ["-e", sql]
                }
                return (try? Shell.run(cmd, environment: env, check: false).status) == 0
            }

            // A colleague creates a database and a table: they must survive turning sharing off.
            XCTAssertTrue(remote(user: share.user, password: share.password, sql: "CREATE DATABASE generale"))
            XCTAssertTrue(remote(user: share.user, password: share.password, database: "generale",
                                 sql: "CREATE TABLE users (id int); INSERT INTO users VALUES (1)"))

            XCTAssertTrue(remote(user: share.user, password: share.password), "\(kind): share login failed")
            XCTAssertFalse(remote(user: share.user, password: "wrong"), "\(kind): wrong password accepted")
            XCTAssertFalse(remote(user: kind.defaultUser!, password: ""), "\(kind): superuser reachable from LAN")

            let local = try await m.disableNetworkShare(shared)
            XCTAssertNil(local.networkShare)
            XCTAssertFalse(remote(user: share.user, password: share.password), "\(kind): still shared")
            XCTAssertNoThrow(try m.databaseNames(in: local), "\(kind): local access broken")
            let count = try XCTUnwrap(kind.clientCommand(local, sql: kind == .postgresql
                ? "SELECT count(*) FROM users" : "SELECT count(*) FROM generale.users",
                database: "generale"))
            XCTAssertEqual(try Shell.run(count, environment: kind.environment).output
                .trimmingCharacters(in: .whitespacesAndNewlines), "1", "\(kind): colleague's data lost")
            try m.stop(local)
        }
    }
}
