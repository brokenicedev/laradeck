import XCTest
@testable import laradeck

final class ArtisanCommandDiscoveryTests: XCTestCase {
    func testParseCommandsReadsTopLevelCommandsNotNestedUnderApplication() {
        let json: [String: Any] = [
            "application": [
                "name": "Laravel Framework",
                "version": "12.68.0",
            ],
            "commands": [
                [
                    "name": "nitrogen:publish",
                    "description": "Publish Nitrogen assets",
                    "hidden": false,
                ],
                [
                    "name": "make:model",
                    "description": "Create a new Eloquent model class",
                    "hidden": false,
                ],
                [
                    "name": "secret:internal",
                    "description": "Hidden helper",
                    "hidden": true,
                ],
            ],
        ]

        let parsed = ArtisanCommandDiscovery.parseCommands(from: json)
        XCTAssertEqual(parsed.map(\.name), ["nitrogen:publish", "make:model", "secret:internal"])
        XCTAssertEqual(parsed.last?.hidden, true)
    }

    func testParseCommandsEmptyWhenLegacyNestedShapeMissingTopLevel() {
        let nestedOnly: [String: Any] = [
            "application": [
                "name": "Laravel Framework",
                "commands": [
                    ["name": "legacy:cmd", "description": "Only nested", "hidden": false],
                ],
            ],
        ]
        let parsed = ArtisanCommandDiscovery.parseCommands(from: nestedOnly)
        XCTAssertEqual(parsed.map(\.name), ["legacy:cmd"])
    }

    func testExtractJSONToleratesShellPreambleViaDiscoverParse() {
        // Ensure a realistic Laravel 13 payload (commands at root) yields many options after filters.
        let data = try! Data(contentsOf: URL(fileURLWithPath: "/tmp/artisan-list-tp.json"))
        let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let parsed = ArtisanCommandDiscovery.parseCommands(from: object)
        XCTAssertGreaterThan(parsed.count, 100)
        XCTAssertTrue(parsed.contains(where: { $0.name.hasPrefix("nitrogen:") }))
    }
}
