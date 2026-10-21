import XCTest
@testable import laradeck

final class PackageManagerDetectorTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try TemporaryDirectory.make()
    }

    override func tearDownWithError() throws {
        TemporaryDirectory.remove(tempDir)
        tempDir = nil
    }

    func testDetectsPnpmFromLockFile() throws {
        try "lock".write(to: tempDir.appendingPathComponent("pnpm-lock.yaml"), atomically: true, encoding: .utf8)
        let detection = PackageManagerDetector.detectDetailed(at: tempDir.path)
        XCTAssertEqual(detection.manager, .pnpm)
        XCTAssertEqual(detection.sourceFile, "pnpm-lock.yaml")
        XCTAssertTrue(detection.isConfident)
    }

    func testDetectsYarnFromLockFile() throws {
        try "lock".write(to: tempDir.appendingPathComponent("yarn.lock"), atomically: true, encoding: .utf8)
        XCTAssertEqual(PackageManagerDetector.detect(at: tempDir.path), .yarn)
    }

    func testDetectsNpmFromPackageLock() throws {
        try "{}".write(to: tempDir.appendingPathComponent("package-lock.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(PackageManagerDetector.detect(at: tempDir.path), .npm)
    }

    func testFallsBackToNpmWhenOnlyPackageJsonExists() throws {
        try "{}".write(to: tempDir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let detection = PackageManagerDetector.detectDetailed(at: tempDir.path)
        XCTAssertEqual(detection.manager, .npm)
        XCTAssertNil(detection.sourceFile)
        XCTAssertFalse(detection.isConfident)
    }

    func testReturnsNoneWhenNoFrontendManifest() {
        XCTAssertEqual(PackageManagerDetector.detect(at: tempDir.path), .none)
    }
}
