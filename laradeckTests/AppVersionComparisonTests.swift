import XCTest
@testable import laradeck

final class AppVersionComparisonTests: XCTestCase {
    func testRemoteBuildHigherIsNewer() {
        let remote = AppVersionInfo(
            latest: "1.0.0",
            build: 5,
            notes: nil,
            directURL: nil,
            masURL: nil,
            minOS: nil
        )
        let local = LocalAppVersion(marketing: "1.0.0", build: 1)
        XCTAssertTrue(AppVersionComparison.isRemoteNewer(remote, than: local))
    }

    func testSameBuildNotNewer() {
        let remote = AppVersionInfo(
            latest: "1.0.0",
            build: 1,
            notes: nil,
            directURL: nil,
            masURL: nil,
            minOS: nil
        )
        let local = LocalAppVersion(marketing: "1.0.0", build: 1)
        XCTAssertFalse(AppVersionComparison.isRemoteNewer(remote, than: local))
    }

    func testMarketingFallbackWhenBuildEqual() {
        let remote = AppVersionInfo(
            latest: "1.0.1",
            build: 3,
            notes: nil,
            directURL: nil,
            masURL: nil,
            minOS: nil
        )
        let local = LocalAppVersion(marketing: "1.0.0", build: 3)
        XCTAssertTrue(AppVersionComparison.isRemoteNewer(remote, than: local))
    }

    func testOlderRemoteNotNewer() {
        let remote = AppVersionInfo(
            latest: "0.9.0",
            build: 99,
            notes: nil,
            directURL: nil,
            masURL: nil,
            minOS: nil
        )
        let local = LocalAppVersion(marketing: "1.0.0", build: 4)
        XCTAssertFalse(AppVersionComparison.isRemoteNewer(remote, than: local))
    }

    func testSameMarketingHigherBuildIsNewer() {
        let remote = AppVersionInfo(
            latest: "1.0.2",
            build: 2,
            notes: nil,
            directURL: nil,
            masURL: nil,
            minOS: nil
        )
        let local = LocalAppVersion(marketing: "1.0.2", build: 1)
        XCTAssertTrue(AppVersionComparison.isRemoteNewer(remote, than: local))
    }

    func testSameMarketingSameBuildNotNewer() {
        let remote = AppVersionInfo(
            latest: "1.0.2",
            build: 1,
            notes: nil,
            directURL: nil,
            masURL: nil,
            minOS: nil
        )
        let local = LocalAppVersion(marketing: "1.0.2", build: 1)
        XCTAssertFalse(AppVersionComparison.isRemoteNewer(remote, than: local))
    }
}
