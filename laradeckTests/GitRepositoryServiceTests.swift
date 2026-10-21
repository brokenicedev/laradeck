import XCTest
@testable import laradeck

final class GitRepositoryServiceTests: XCTestCase {
    func testCurrentBranchReturnsNilOutsideGitRepo() async {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: path) }

        let branch = await GitRepositoryService.currentBranch(at: path.path)
        XCTAssertNil(branch)
    }

    func testCurrentBranchReadsCheckedOutBranch() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: path) }

        try runGit(["init"], at: path.path)
        try runGit(["checkout", "-b", "feature/test-branch"], at: path.path)

        let branch = await GitRepositoryService.currentBranch(at: path.path)
        XCTAssertEqual(branch, "feature/test-branch")
    }

    private func runGit(_ arguments: [String], at projectPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", projectPath] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
