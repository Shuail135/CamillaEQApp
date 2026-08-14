import XCTest
@testable import CamillaApp

final class AppUpdateCheckerTests: XCTestCase {
    func testDetectsNewerVersion() {
        XCTAssertTrue(AppUpdateChecker.isVersion("v0.1.2", newerThan: "0.1.1"))
        XCTAssertTrue(AppUpdateChecker.isVersion("1.0.0", newerThan: "0.9.9"))
        XCTAssertTrue(AppUpdateChecker.isVersion("0.2", newerThan: "0.1.99"))
    }

    func testRejectsSameOrOlderVersion() {
        XCTAssertFalse(AppUpdateChecker.isVersion("v0.1.1", newerThan: "0.1.1"))
        XCTAssertFalse(AppUpdateChecker.isVersion("0.1.0", newerThan: "0.1.1"))
        XCTAssertFalse(AppUpdateChecker.isVersion("1.0", newerThan: "1.0.0"))
    }

    func testRejectsInvalidVersion() {
        XCTAssertFalse(AppUpdateChecker.isVersion("latest", newerThan: "0.1.1"))
    }

    func testBuildsExpectedReleaseArchiveName() {
        XCTAssertEqual(
            AppUpdateChecker.archiveName(for: "v0.1.2"),
            "CamillaApp-v0.1.2-app.zip"
        )
        XCTAssertEqual(
            AppUpdateChecker.archiveName(for: "0.1.2"),
            "CamillaApp-v0.1.2-app.zip"
        )
    }
}
