import XCTest
@testable import laradeck

final class NpmScriptsDetectorTests: XCTestCase {
    private var fixturePath: String!

    override func setUpWithError() throws {
        fixturePath = TestFixtures.laravelMinimal.path
    }

    func testScriptsReadsPackageJson() {
        let scripts = NpmScriptsDetector.scripts(at: fixturePath)
        XCTAssertEqual(scripts["dev"], "vite")
        XCTAssertEqual(scripts["watch"], "vite build --watch")
    }
}
