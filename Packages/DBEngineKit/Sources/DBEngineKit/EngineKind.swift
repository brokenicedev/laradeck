import Foundation

/// Supported engines and the per-engine knowledge DBngin hard-codes:
/// default port, server binary, first-run initialisation and launch arguments.
public enum EngineKind: String, Codable, CaseIterable, Sendable {
    case postgresql
    case mysql
    case redis

    public var displayName: String {
        switch self {
        case .postgresql: "PostgreSQL"
        case .mysql: "MySQL"
        case .redis: "Redis"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .postgresql: 5432
        case .mysql: 3306
        case .redis: 6379
        }
    }

    /// Name of the long-running server executable inside `bin/`.
    public var serverBinary: String {
        switch self {
        case .postgresql: "postgres"
        case .mysql: "mysqld"
        case .redis: "redis-server"
        }
    }

    public var defaultUser: String? {
        switch self {
        case .postgresql: "postgres"
        case .mysql: "root"
        case .redis: nil
        }
    }

    /// Database files live in a subfolder so the service folder can also hold
    /// the plist and logs without upsetting initdb / mysqld --initialize.
    func dbFilesDir(_ s: Service) -> URL {
        switch self {
        case .postgresql, .mysql: s.dataURL.appendingPathComponent("data", isDirectory: true)
        case .redis: s.dataURL
        }
    }

    public func logFile(_ s: Service) -> URL {
        s.dataURL.appendingPathComponent("\(serverBinary).log")
    }

    /// Commands that must succeed once before the first start (DBngin: "Initializing database...").
    func initCommands(_ s: Service) -> [[String]] {
        let bin = s.binaryURL
        let data = dbFilesDir(s).path
        switch self {
        case .postgresql:
            // DBngin: initdb ... --encoding=UTF-8 --locale=en_US.UTF-8, user "postgres", empty password.
            return [[bin.appendingPathComponent("initdb").path,
                     "-D", data, "-U", "postgres", "--auth=trust",
                     "--encoding=UTF-8", "--locale=en_US.UTF-8"]]
        case .mysql:
            // DBngin: mysqld --initialize-insecure (root with empty password).
            return [[bin.appendingPathComponent("mysqld").path,
                     "--initialize-insecure",
                     "--basedir=\(s.binariesPath)", "--datadir=\(data)"]]
        case .redis:
            return []
        }
    }

    /// Environment for init commands and the launchd job. launchd starts jobs with no
    /// locale; Homebrew's PostgreSQL then aborts with "postmaster became multithreaded
    /// during startup" unless LC_ALL is set.
    var environment: [String: String] {
        switch self {
        case .postgresql: ["LC_ALL": "en_US.UTF-8", "LANG": "en_US.UTF-8"]
        case .mysql, .redis: [:]
        }
    }

    /// `ProgramArguments` for the launchd job.
    func serverArguments(_ s: Service) -> [String] {
        let server = s.binaryURL.appendingPathComponent(serverBinary).path
        let data = dbFilesDir(s).path
        switch self {
        case .postgresql:
            return [server, "-D", data, "-p", String(s.port),
                    "-c", "listen_addresses=\(s.isShared ? "*" : "localhost")"]
        case .mysql:
            return [server,
                    "--port=\(s.port)",
                    "--bind-address=\(s.isShared ? "*" : "127.0.0.1")",
                    "--basedir=\(s.binariesPath)",
                    "--datadir=\(data)",
                    "--socket=/tmp/mysql_\(s.port).sock",
                    "--pid-file=\(s.dataURL.appendingPathComponent("mysql.pid").path)",
                    "--log-error=\(logFile(s).path)",
                    "--mysqlx=OFF"] // avoid X-protocol port clashes between instances
        case .redis:
            return [server, "--port", String(s.port), "--pidfile", "redis.pid",
                    "--daemonize", "no", "--dir", data]
        }
    }

    // MARK: Network sharing

    /// Redis can't give remote clients a password while local ones keep none.
    public var supportsNetworkShare: Bool { self != .redis }

    /// Statements that create the share user or refresh its password.
    /// Passwords are alphanumeric (see `NetworkShare.generate`), so plain quoting is enough.
    func shareUserSQL(_ share: NetworkShare) -> [String] {
        let user = share.user, password = share.password
        switch self {
        case .postgresql:
            return [
                "DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '\(user)') "
                    + "THEN CREATE ROLE \"\(user)\" LOGIN SUPERUSER; END IF; END $$",
                "SET password_encryption = 'scram-sha-256'; "
                    + "ALTER ROLE \"\(user)\" LOGIN SUPERUSER PASSWORD '\(password)'",
            ]
        case .mysql:
            return [
                "CREATE USER IF NOT EXISTS '\(user)'@'%' IDENTIFIED BY '\(password)'",
                "ALTER USER '\(user)'@'%' IDENTIFIED BY '\(password)'",
                "GRANT ALL PRIVILEGES ON *.* TO '\(user)'@'%'",
            ]
        case .redis:
            return []
        }
    }

    /// PostgreSQL only, run in every database before the DROP: hands what colleagues created
    /// (tables, sequences, whole databases) to `postgres` so the data stays, and drops grants.
    /// Ownership is per database, hence one run per database.
    func releaseShareUserSQL(_ share: NetworkShare) -> String? {
        guard self == .postgresql else { return nil }
        return "REASSIGN OWNED BY \"\(share.user)\" TO postgres; DROP OWNED BY \"\(share.user)\""
    }

    /// Closes colleagues' open sessions so the restart afterwards doesn't wait on them.
    func terminateShareSessionsSQL(_ share: NetworkShare) -> String? {
        guard self == .postgresql else { return nil }
        return "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = '\(share.user)'"
    }

    func dropShareUserSQL(_ share: NetworkShare) -> [String] {
        switch self {
        case .postgresql: ["DROP ROLE IF EXISTS \"\(share.user)\""]
        case .mysql: ["DROP USER IF EXISTS '\(share.user)'@'%'"]
        case .redis: []
        }
    }

    /// pg_hba.conf sits next to the database files; nil for engines without one.
    func hbaFile(_ s: Service) -> URL? {
        self == .postgresql ? dbFilesDir(s).appendingPathComponent("pg_hba.conf") : nil
    }

    // MARK: Client queries

    var listDatabasesSQL: String {
        switch self {
        case .postgresql: "SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY datname"
        case .mysql: "SHOW DATABASES"
        case .redis: ""
        }
    }

    func createDatabaseSQL(_ name: String) -> String? {
        switch self {
        case .postgresql:
            return "CREATE DATABASE \"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
        case .mysql:
            return "CREATE DATABASE `\(name.replacingOccurrences(of: "`", with: "``"))` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
        case .redis:
            return nil
        }
    }

    /// Runs one SQL statement as the default superuser, printing bare rows.
    func clientCommand(_ s: Service, sql: String, database: String = "postgres") -> [String]? {
        let bin = s.binaryURL
        switch self {
        case .postgresql:
            return [bin.appendingPathComponent("psql").path, "-h", "127.0.0.1", "-p", String(s.port),
                    "-U", "postgres", "-d", database, "-X", "-q", "-t", "-A", "-v", "ON_ERROR_STOP=1", "-c", sql]
        case .mysql:
            return [bin.appendingPathComponent("mysql").path, "-h", "127.0.0.1", "-P", String(s.port),
                    "-u", "root", "--batch", "--skip-column-names", "-e", sql]
        case .redis:
            return nil
        }
    }

    /// Same URL shapes DBngin hands to TablePlus.
    public func connectionURL(port: Int, name: String) -> String {
        let n = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        switch self {
        case .postgresql: return "postgresql://postgres@127.0.0.1:\(port)/postgres?name=\(n)"
        case .mysql: return "mysql://root@127.0.0.1:\(port)?name=\(n)"
        case .redis: return "redis://127.0.0.1:\(port)?name=\(n)"
        }
    }
}
