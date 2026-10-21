import XCTest
@testable import laradeck

final class LaravelDetectorTests: XCTestCase {
    private var fixturePath: String!
    private var tempDir: URL!

    override func setUpWithError() throws {
        fixturePath = TestFixtures.laravelMinimal.path
        tempDir = try TemporaryDirectory.make()
    }

    override func tearDownWithError() throws {
        TemporaryDirectory.remove(tempDir)
        tempDir = nil
    }

    func testIsLaravelProjectRequiresCoreEntries() throws {
        let fm = FileManager.default
        for entry in ["artisan", "composer.json", "app", "bootstrap", "config"] {
            try fm.createDirectory(at: tempDir.appendingPathComponent(entry), withIntermediateDirectories: true)
        }
        XCTAssertTrue(LaravelDetector.isLaravelProject(at: tempDir.path))
    }

    func testIsLaravelProjectReturnsFalseWhenArtisanMissing() {
        XCTAssertFalse(LaravelDetector.isLaravelProject(at: tempDir.path))
    }

    func testDetectMetadataReadsComposerAndEnv() {
        let metadata = LaravelDetector.detectMetadata(at: fixturePath)
        XCTAssertEqual(metadata.appName, "acme/demo")
        XCTAssertEqual(metadata.laravelConstraint, "^11.0")
        XCTAssertTrue(metadata.hasHorizon)
        XCTAssertTrue(metadata.hasSail)
        XCTAssertEqual(metadata.appURL, "http://localhost:8000")
        XCTAssertEqual(metadata.appEnv, "local")
        XCTAssertNil(metadata.safeEnvironment["DB_PASSWORD"])
        XCTAssertNil(metadata.safeEnvironment["API_TOKEN"])
        XCTAssertEqual(metadata.safeEnvironment["APP_NAME"], "Demo App")
    }
}
