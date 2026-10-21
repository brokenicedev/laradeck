import XCTest
@testable import laradeck

final class NonInteractiveCommandFlagsTests: XCTestCase {
    func testArtisanInsertsNoInteractionFlag() {
        let result = NonInteractiveCommandFlags.arguments(
            executable: "php",
            resolvedExecutablePath: "/usr/bin/php",
            arguments: ["artisan", "migrate"]
        )
        XCTAssertEqual(result, ["artisan", "-n", "migrate"])
    }

    func testArtisanDoesNotDuplicateExistingFlag() {
        let args = ["artisan", "--no-interaction", "migrate"]
        let result = NonInteractiveCommandFlags.arguments(
            executable: "php",
            resolvedExecutablePath: "/usr/bin/php",
            arguments: args
        )
        XCTAssertEqual(result, args)
    }

    func testComposerAppendsNoInteractionFlag() {
        let result = NonInteractiveCommandFlags.arguments(
            executable: "composer",
            resolvedExecutablePath: "/usr/local/bin/composer",
            arguments: ["install"]
        )
        XCTAssertEqual(result, ["install", "--no-interaction"])
    }

    func testComposerDoesNotDuplicateExistingFlag() {
        let args = ["install", "--no-interaction"]
        let result = NonInteractiveCommandFlags.arguments(
            executable: "composer",
            resolvedExecutablePath: "/usr/local/bin/composer",
            arguments: args
        )
        XCTAssertEqual(result, args)
    }

    func testUnrelatedExecutableUnchanged() {
        let args = ["dev", "--host"]
        let result = NonInteractiveCommandFlags.arguments(
            executable: "npm",
            resolvedExecutablePath: "/usr/local/bin/npm",
            arguments: args
        )
        XCTAssertEqual(result, args)
    }
}
