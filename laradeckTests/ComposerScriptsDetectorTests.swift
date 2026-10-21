import XCTest
@testable import laradeck

final class ComposerScriptsDetectorTests: XCTestCase {
    private var fixturePath: String!

    override func setUpWithError() throws {
        fixturePath = TestFixtures.laravelMinimal.path
    }

    func testScriptsIgnoresLifecycleHooks() {
        let scripts = ComposerScriptsDetector.scripts(at: fixturePath)
        XCTAssertNil(scripts["post-autoload-dump"])
        XCTAssertEqual(scripts["dev"], "php artisan serve")
    }

    func testScriptsUsesFirstLineOfArrayValue() {
        let scripts = ComposerScriptsDetector.scripts(at: fixturePath)
        XCTAssertEqual(scripts["test"], "vendor/bin/phpunit")
    }
}
