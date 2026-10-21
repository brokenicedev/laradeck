import PhpSwitcherCore
import XCTest
@testable import laradeck

final class ProjectPhpRequirementTests: XCTestCase {
    func testReadsRequirePhpFromComposerJSON() throws {
        let json = #"{"require": {"php": "^8.2", "laravel/framework": "^11.0"}}"#
        let constraint = try XCTUnwrap(ProjectPhpRequirement.constraint(fromComposerJSON: Data(json.utf8)))
        XCTAssertEqual(constraint.description, "^8.2")
        XCTAssertTrue(constraint.satisfies(VersionNumber(major: 8, minor: 4, patch: 1)))
        XCTAssertFalse(constraint.satisfies(VersionNumber(major: 8, minor: 1, patch: 30)))
    }

    func testMissingOrUnreadableRequirementIsNil() {
        XCTAssertNil(ProjectPhpRequirement.constraint(fromComposerJSON: Data(#"{"require": {}}"#.utf8)))
        XCTAssertNil(ProjectPhpRequirement.constraint(fromComposerJSON: Data("not json".utf8)))
        XCTAssertNil(ProjectPhpRequirement.constraint(fromComposerJSON: Data(#"{"require": {"php": "latest"}}"#.utf8)))
    }

    func testSailProjectsAreNotChecked() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("php-req-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"require": {"php": "^8.4"}}"#.write(to: dir.appendingPathComponent("composer.json"), atomically: true, encoding: .utf8)

        let native = Project(name: "a", path: dir.path, environment: .native, packageManager: .npm, processes: [])
        let sail = Project(name: "b", path: dir.path, environment: .sail, packageManager: .npm, processes: [])
        XCTAssertNotNil(ProjectPhpRequirement.constraint(for: native))
        XCTAssertNil(ProjectPhpRequirement.constraint(for: sail))
    }
}
