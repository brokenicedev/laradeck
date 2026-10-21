import XCTest
@testable import laradeck

final class ProjectNodeRequirementTests: XCTestCase {
    private func v(_ text: String) -> NodeVersion { NodeVersion(text)! }

    private func req(_ text: String) throws -> NodeRequirement {
        try XCTUnwrap(NodeRequirement(text), "could not parse \(text)")
    }

    func testNvmrcValues() throws {
        XCTAssertTrue(try req("20").satisfies(v("20.19.2")))
        XCTAssertFalse(try req("20").satisfies(v("22.0.0")))
        XCTAssertTrue(try req("v20.19.2").satisfies(v("20.19.2")))
        XCTAssertFalse(try req("v20.19.2").satisfies(v("20.19.3")))
        XCTAssertTrue(try req("lts/iron").satisfies(v("20.1.0")))
        XCTAssertFalse(try req("lts/iron").satisfies(v("22.1.0")))
        XCTAssertTrue(try req("lts/*").satisfies(v("22.22.0")))
        XCTAssertFalse(try req("lts/*").satisfies(v("23.1.0")))
        XCTAssertTrue(try req("node").satisfies(v("25.0.0")))
    }

    func testSemverRanges() throws {
        let vite = try req("^20.19.0 || >=22.12.0")
        XCTAssertTrue(vite.satisfies(v("20.19.2")))
        XCTAssertFalse(vite.satisfies(v("20.18.0")))
        XCTAssertFalse(vite.satisfies(v("21.5.0")))
        XCTAssertFalse(vite.satisfies(v("22.11.0")))
        XCTAssertTrue(vite.satisfies(v("22.22.0")))

        XCTAssertTrue(try req(">=18").satisfies(v("18.0.0")))
        XCTAssertFalse(try req(">=18").satisfies(v("16.20.0")))
        XCTAssertTrue(try req(">= 18 < 21").satisfies(v("20.1.0")))
        XCTAssertFalse(try req(">= 18 < 21").satisfies(v("21.0.0")))
        XCTAssertTrue(try req("20.x").satisfies(v("20.5.1")))
        XCTAssertTrue(try req("~20.1").satisfies(v("20.1.9")))
        XCTAssertFalse(try req("~20.1").satisfies(v("20.2.0")))
        XCTAssertTrue(try req("18 - 20").satisfies(v("20.99.0")))
        XCTAssertFalse(try req("18 - 20").satisfies(v("21.0.0")))
        XCTAssertTrue(try req(">20").satisfies(v("21.0.0")))
        XCTAssertFalse(try req(">20").satisfies(v("20.9.0")))
        XCTAssertNil(NodeRequirement("banana"))
    }

    func testBestMatchAndInstallHint() throws {
        let installed = ["18.18.2", "20.19.2", "22.22.0"].map(v)
        XCTAssertEqual(try req("^20.19.0 || >=22.12.0").bestMatch(in: installed), v("22.22.0"))
        XCTAssertEqual(try req("20").bestMatch(in: installed), v("20.19.2"))
        XCTAssertNil(try req("24").bestMatch(in: installed))
        XCTAssertEqual(try req("24").installHint, "24")
        XCTAssertEqual(try req(">=22.12.0").installHint, "22.12.0")
        XCTAssertEqual(try req("lts/*").installHint, "lts/*")
    }

    func testReadsFilesInPriorityOrder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("node-req-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try #"{"engines": {"node": ">=18"}}"#.write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectNodeRequirement.read(atPath: dir.path)?.source, .engines)

        try "# comment\nv20.19.2\n".write(to: dir.appendingPathComponent(".nvmrc"), atomically: true, encoding: .utf8)
        let fromNvmrc = try XCTUnwrap(ProjectNodeRequirement.read(atPath: dir.path))
        XCTAssertEqual(fromNvmrc.source, .nvmrc)
        XCTAssertEqual(fromNvmrc.requirement.description, "v20.19.2")

        let sail = Project(name: "s", path: dir.path, environment: .sail, packageManager: .npm, processes: [])
        XCTAssertNil(ProjectNodeRequirement.read(for: sail))
    }

    func testLatestReleasePerMajor() {
        let json = """
        [{"version":"v24.1.0","date":"2026-05-01","lts":false},
         {"version":"v22.22.0","date":"2026-01-10","lts":"Jod"},
         {"version":"v22.21.0","date":"2025-12-01","lts":"Jod"},
         {"version":"v16.20.2","date":"2023-08-08","lts":"Gallium"}]
        """
        let releases = NodeRelease.latestPerMajor(fromIndexJSON: Data(json.utf8))
        XCTAssertEqual(releases.map(\.version.description), ["24.1.0", "22.22.0"])
        XCTAssertNil(releases[0].lts)
        XCTAssertEqual(releases[1].lts, "Jod")
    }
}
