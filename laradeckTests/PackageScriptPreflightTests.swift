import XCTest
@testable import laradeck

final class PackageScriptPreflightTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"scripts":{"dev":"vite","build":"vite build"}}"#.utf8)
            .write(to: directory.appendingPathComponent("package.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testScriptName() {
        XCTAssertEqual(PackageScriptPreflight.scriptName(executable: "npm", arguments: ["run", "watch"]), "watch")
        XCTAssertEqual(PackageScriptPreflight.scriptName(executable: "/opt/homebrew/bin/pnpm", arguments: ["run", "dev"]), "dev")
        XCTAssertNil(PackageScriptPreflight.scriptName(executable: "npm", arguments: ["install"]))
        XCTAssertNil(PackageScriptPreflight.scriptName(executable: "php", arguments: ["run", "x"]))
    }

    func testExistingScriptPasses() {
        XCTAssertNil(PackageScriptPreflight.problem(executable: "npm", arguments: ["run", "dev"], directory: directory.path))
        XCTAssertNil(PackageScriptPreflight.problem(executable: "php", arguments: ["artisan", "serve"], directory: directory.path))
    }

    func testMissingScriptListsAvailableOnes() throws {
        let message = try XCTUnwrap(PackageScriptPreflight.problem(executable: "npm", arguments: ["run", "watch"], directory: directory.path))
        XCTAssertTrue(message.contains("\"watch\""))
        XCTAssertTrue(message.contains("build, dev"))
    }

    func testMissingPackageJSONAndDirectory() throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent("package.json"))
        XCTAssertNotNil(PackageScriptPreflight.problem(executable: "npm", arguments: ["run", "dev"], directory: directory.path))
        XCTAssertNotNil(PackageScriptPreflight.problem(executable: "php", arguments: ["-v"], directory: directory.path + "/nope"))
    }
}
