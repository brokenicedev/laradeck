import XCTest
@testable import laradeck

final class ProjectColorPaletteTests: XCTestCase {
    func testDefaultHexIsStableForSameSeed() {
        let first = ProjectColorPalette.defaultHex(for: "My Laravel App")
        let second = ProjectColorPalette.defaultHex(for: "My Laravel App")
        XCTAssertEqual(first, second)
        XCTAssertTrue(ProjectColorPalette.hexValues.contains(first))
    }

    func testDefaultHexCanDifferAcrossSeeds() {
        let values = Set(["Alpha", "Beta", "Gamma", "Delta"].map(ProjectColorPalette.defaultHex(for:)))
        XCTAssertGreaterThan(values.count, 1)
    }
}
