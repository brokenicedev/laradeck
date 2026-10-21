import Testing
import Foundation
@testable import PhpSwitcherCore

@Suite struct VersionParsingTests {
    @Test func parsesPhpConfigOutput() {
        #expect(VersionNumber.parse("8.3.12\n") == VersionNumber(major: 8, minor: 3, patch: 12))
    }

    @Test func parsesPhpDashV() {
        let output = "PHP 8.4.25 (cli) (built: Sep  1 2026) (NTS)\nCopyright (c) The PHP Group"
        #expect(VersionNumber.parse(output)?.short == "8.4")
    }

    @Test func parsesKegFolderWithRevision() {
        #expect(VersionNumber.parse("8.2.29_1") == VersionNumber(major: 8, minor: 2, patch: 29))
    }

    @Test func ordering() {
        #expect(VersionNumber(major: 7, minor: 4) < VersionNumber(major: 8, minor: 0))
        #expect(VersionNumber(major: 8, minor: 3, patch: 1) < VersionNumber(major: 8, minor: 3, patch: 10))
    }
}

@Suite struct FormulaTests {
    @Test func acceptsPhpFormulae() {
        #expect(PhpInstallation.isPhpFormulaName("php"))
        #expect(PhpInstallation.isPhpFormulaName("php@8.3"))
        #expect(PhpInstallation.isPhpFormulaName("php@5.6"))
    }

    @Test func rejectsOtherFormulae() {
        #expect(!PhpInstallation.isPhpFormulaName("phpredis@8.3"))
        #expect(!PhpInstallation.isPhpFormulaName("php-cs-fixer"))
        #expect(!PhpInstallation.isPhpFormulaName("php@8"))
    }

    @Test func readsActiveFromCellarPath() {
        let active = ActivePhp.fromCellarPath("/opt/homebrew/Cellar/php@8.4/8.4.25/bin/php")
        #expect(active == ActivePhp(formula: "php@8.4", version: VersionNumber(major: 8, minor: 4, patch: 25)))
        #expect(ActivePhp.fromCellarPath("/usr/bin/php") == nil)
    }

    @Test func dedupePrefersPrimaryFormula() {
        let list = [
            PhpInstallation(formula: "php@8.5", version: VersionNumber(major: 8, minor: 5, patch: 0)),
            PhpInstallation(formula: "php", version: VersionNumber(major: 8, minor: 5, patch: 0)),
            PhpInstallation(formula: "php@8.3", version: VersionNumber(major: 8, minor: 3, patch: 1)),
        ]
        #expect(Homebrew.deduplicate(list).map(\.formula) == ["php", "php@8.3"])
    }
}

@Suite struct PlanTests {
    let installed = [
        PhpInstallation(formula: "php", version: VersionNumber(major: 8, minor: 5)),
        PhpInstallation(formula: "php@8.4", version: VersionNumber(major: 8, minor: 4)),
        PhpInstallation(formula: "php@8.3", version: VersionNumber(major: 8, minor: 3)),
    ]

    @Test func withoutValetOnlyRelinks() {
        let steps = PhpSwitcher.plan(target: installed[2], installed: installed, runningServices: [], usesValet: false)
        #expect(steps == [.unlink("php"), .unlink("php@8.4"), .unlink("php@8.3"), .link("php@8.3")])
    }

    @Test func withoutValetMovesRunningService() {
        let steps = PhpSwitcher.plan(target: installed[2], installed: installed, runningServices: ["php@8.4"], usesValet: false)
        #expect(steps == [
            .unlink("php"), .unlink("php@8.4"), .service(.stop, "php@8.4"), .unlink("php@8.3"),
            .link("php@8.3"), .service(.restart, "php@8.3"),
        ])
    }

    @Test func valetKeepsIsolatedVersionsRunning() {
        let steps = PhpSwitcher.plan(
            target: installed[2], installed: installed,
            runningServices: ["php@8.4", "php"], usesValet: true, isolatedVersions: ["8.5"]
        )
        #expect(steps == [
            .unlink("php"),                                   // 8.5 is isolated: not stopped
            .unlink("php@8.4"), .service(.stop, "php@8.4"),
            .unlink("php@8.3"),
            .link("php@8.3"),
            .prepareValetFpm("8.3"),
            .service(.restart, "php@8.3"),
            .linkValetSocket("8.3"),
            .service(.restart, "nginx"),
        ])
    }
}

/// Fake shell: records every command and answers from a table.
final class FakeShell: Shell, @unchecked Sendable {
    var commands: [String] = []
    var responses: [String: ShellResult] = [:]

    func run(_ command: String) async throws -> ShellResult {
        commands.append(command)
        for (needle, result) in responses where command.contains(needle) {
            return result
        }
        return ShellResult(exitCode: 0, stdout: "", stderr: "")
    }
}

/// A throwaway directory removed at the end of the test.
final class TempDir {
    let path: String
    init() {
        path = FileManager.default.temporaryDirectory.appendingPathComponent("phpmonit-tests-\(UUID().uuidString)").path
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(atPath: path) }

    @discardableResult
    func write(_ relative: String, _ contents: String) -> String {
        let full = "\(path)/\(relative)"
        try! FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! contents.write(toFile: full, atomically: true, encoding: .utf8)
        return full
    }

    func read(_ relative: String) -> String {
        (try? String(contentsOfFile: "\(path)/\(relative)", encoding: .utf8)) ?? ""
    }
}

@Suite struct ServicesTests {
    @Test func parsesRunningPhpServicesWithSudo() async {
        let shell = FakeShell()
        shell.responses["services list --json"] = ShellResult(exitCode: 0, stdout: """
        [{"name":"php@8.4","status":"started","user":"root"},{"name":"php","status":"none"},
         {"name":"nginx","status":"started"},{"name":"php@8.3","status":"error"}]
        """, stderr: "")
        let services = Services(homebrew: Homebrew(prefix: "/opt/homebrew", shell: shell), useSudo: true)
        #expect(await services.runningPhpServices() == ["php@8.4"])
        #expect(shell.commands.first == "sudo -n /opt/homebrew/bin/brew services list --json")
    }
}

@Suite struct ConfigTests {
    @Test func parsesIniListFromPhpIni() {
        let output = """
        Loaded Configuration File:         /opt/homebrew/etc/php/8.4/php.ini
        Additional .ini files parsed:      /opt/homebrew/etc/php/8.4/conf.d/20-redis.ini,
        /opt/homebrew/etc/php/8.4/conf.d/20-xdebug.ini
        """
        #expect(PhpConfig.parseIniList(output) == [
            "/opt/homebrew/etc/php/8.4/php.ini",
            "/opt/homebrew/etc/php/8.4/conf.d/20-redis.ini",
            "/opt/homebrew/etc/php/8.4/conf.d/20-xdebug.ini",
        ])
    }

    @Test func parsesExtensionsLikePhpMonitor() {
        let ini = """
        [xdebug]
        zend_extension="/opt/homebrew/opt/xdebug@8.4/xdebug.so"
        ; extension="redis.so"
        extension=bz2
        """
        let exts = PhpExtension.parse(contents: ini, path: "/x.ini")
        #expect(exts.map(\.name) == ["xdebug", "redis"])
        #expect(exts.map(\.enabled) == [true, false])
        #expect(exts[0].toggledLine == ";zend_extension=\"/opt/homebrew/opt/xdebug@8.4/xdebug.so\"")
        #expect(exts[1].toggledLine == "extension=\"redis.so\"")
    }

    func config(_ tmp: TempDir, files: [String]) -> PhpConfig {
        let shell = FakeShell()
        shell.responses["--ini"] = ShellResult(exitCode: 0, stdout: files.map { "\(tmp.path)/\($0)" }.joined(separator: ",\n"), stderr: "")
        return PhpConfig(homebrew: Homebrew(prefix: tmp.path, shell: shell), phpBinary: "php", etcDirectory: tmp.path)
    }

    @Test func togglesExtensionInPlace() async throws {
        let tmp = TempDir()
        tmp.write("conf.d/20-redis.ini", "[redis]\nextension=\"redis.so\"\n")
        let config = config(tmp, files: ["conf.d/20-redis.ini"])
        let ext = try #require(await config.extensions().first)
        try config.toggle(ext)
        #expect(tmp.read("conf.d/20-redis.ini") == "[redis]\n;extension=\"redis.so\"\n")
        try config.toggle(try #require(await config.extensions().first))
        #expect(tmp.read("conf.d/20-redis.ini") == "[redis]\nextension=\"redis.so\"\n")
    }

    @Test func setsLimitInLastFileThatDefinesIt() async throws {
        let tmp = TempDir()
        tmp.write("php.ini", "memory_limit = 128M\npost_max_size = 8M\n")
        tmp.write("conf.d/php-memory-limits.ini", "memory_limit = 512M\n")
        let config = config(tmp, files: ["php.ini", "conf.d/php-memory-limits.ini"])

        try await config.set("memory_limit", to: "1G")
        #expect(tmp.read("conf.d/php-memory-limits.ini") == "memory_limit = 1G\n")
        #expect(tmp.read("php.ini").contains("memory_limit = 128M"))

        try await config.set("post_max_size", to: "64M")
        #expect(tmp.read("php.ini").contains("post_max_size = 64M"))

        try await config.set("upload_max_filesize", to: "32M")
        #expect(tmp.read("conf.d/php-memory-limits.ini").hasSuffix("upload_max_filesize = 32M\n"))

        await #expect(throws: ConfigError.self) { try await config.set("memory_limit", to: "lots") }
    }

    @Test func setsXdebugModeOrAddsIt() async throws {
        let tmp = TempDir()
        tmp.write("conf.d/20-xdebug.ini", "[xdebug]\nzend_extension=\"/opt/homebrew/opt/xdebug@8.4/xdebug.so\"\n")
        let config = config(tmp, files: ["conf.d/20-xdebug.ini"])
        #expect(await config.xdebugMode() == nil)

        try await config.setXdebugMode("debug")
        #expect(await config.xdebugMode() == "debug")
        try await config.setXdebugMode("off")
        #expect(tmp.read("conf.d/20-xdebug.ini").hasSuffix("xdebug.mode = off\n"))
        #expect(tmp.read("conf.d/20-xdebug.ini").components(separatedBy: "xdebug.mode").count == 2)
    }
}

@Suite struct ManagerTests {
    @Test func parsesExtensionTap() {
        let files = ["xdebug@8.4.rb", "xdebug@8.3.rb", "phpredis@8.4.rb", "README.md", "imagick@8.4.rb"]
        #expect(ExtensionManager.parseFormulaFiles(files, version: "8.4") == ["imagick", "phpredis", "xdebug"])
    }

    @Test func parsesOutdatedPhp() {
        let json = #"{"formulae":[{"name":"php@8.3"},{"name":"shivammathur/php/php@8.2"},{"name":"nginx"}],"casks":[]}"#
        #expect(PhpVersionManager.parseOutdated(json) == ["php@8.3", "php@8.2"])
    }
}

@Suite struct ValetTests {
    @Test func parsesIsolatedVersion() {
        #expect(Valet.parseIsolatedVersion("# ISOLATED_PHP_VERSION=php@8.2\nserver {") == "8.2")
        #expect(Valet.parseIsolatedVersion("# ISOLATED_PHP_VERSION=81") == "8.1")
        #expect(Valet.parseIsolatedVersion("server {}") == nil)
    }

    @Test func socketName() {
        #expect(Valet.socketName(for: VersionNumber(major: 8, minor: 4)) == "valet84.sock")
    }

    @Test func scansSites() throws {
        let tmp = TempDir()
        let home = tmp.path
        tmp.write("Works/shop/index.php", "")
        tmp.write("Works/blog/index.php", "")
        tmp.write("Elsewhere/api/index.php", "")
        tmp.write("Works/shop (da backup)/index.php", "")   // not a valid hostname: skipped
        tmp.write(".config/valet/Certificates/shop.test.crt", "")
        tmp.write(".config/valet/Nginx/blog.test", "# ISOLATED_PHP_VERSION=php@8.2\n")
        try FileManager.default.createDirectory(atPath: "\(home)/.config/valet/Sites", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: "\(home)/.config/valet/Sites/api", withDestinationPath: "\(home)/Elsewhere/api")
        tmp.write(".config/valet/config.json", #"{"tld":"test","paths":["\#(home)/.config/valet/Sites","\#(home)/Works"]}"#)

        let valet = Valet(home: home, homebrew: Homebrew(prefix: "/nowhere", shell: FakeShell()))
        let sites = valet.sites()
        #expect(sites.map(\.name) == ["api", "blog", "shop"])
        #expect(sites.first { $0.name == "api" }?.linked == true)
        #expect(sites.first { $0.name == "shop" }?.url.absoluteString == "https://shop.test")
        #expect(valet.isolatedVersions() == ["8.2"])
    }

    @Test func createsFpmPoolFromStub() throws {
        let tmp = TempDir()
        tmp.write(".composer/vendor/laravel/valet/cli/stubs/etc-phpfpm-valet.conf",
                  "[valet]\nuser = VALET_USER\nlisten = VALET_HOME_PATH/valet.sock\n")
        tmp.write(".composer/vendor/laravel/valet/cli/stubs/etc-phpfpm-error_log.ini", "error_log=\"VALET_HOME_PATH/Log/php-fpm.log\"\n")
        tmp.write("prefix/etc/php/8.5/php-fpm.d/www.conf", "[www]\n")

        let valet = Valet(home: tmp.path, homebrew: Homebrew(prefix: "\(tmp.path)/prefix", shell: FakeShell()))
        let fixes = try valet.ensureFpmConfiguration(for: VersionNumber(major: 8, minor: 5), user: "luca")

        #expect(fixes.count == 3)
        #expect(tmp.read("prefix/etc/php/8.5/php-fpm.d/valet-fpm.conf")
                == "[valet]\nuser = luca\nlisten = \(tmp.path)/.config/valet/valet85.sock\n")
        #expect(tmp.read("prefix/etc/php/8.5/php-fpm.d/www.conf.disabled-by-phpmon") == "[www]\n")
        #expect(tmp.read("prefix/etc/php/8.5/conf.d/error_log.ini").contains("\(tmp.path)/.config/valet/Log"))
        // Second run: nothing left to fix.
        #expect(try valet.ensureFpmConfiguration(for: VersionNumber(major: 8, minor: 5), user: "luca").isEmpty)
    }
}
