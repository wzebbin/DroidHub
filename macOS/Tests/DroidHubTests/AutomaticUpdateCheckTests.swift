import XCTest
@testable import DroidHub

final class AutomaticUpdateCheckTests: XCTestCase {
    func testFirstCheckAndFiveHourBoundary() {
        let last: TimeInterval = 1_800_000_000
        XCTAssertTrue(AutomaticUpdateCheck.isDue(lastAttempt: 0, now: last))
        XCTAssertFalse(AutomaticUpdateCheck.isDue(lastAttempt: last, now: last + 17_999))
        XCTAssertTrue(AutomaticUpdateCheck.isDue(lastAttempt: last, now: last + 18_000))
    }

    func testOnlyNewerReleasesProduceAutomaticNotices() throws {
        let page = try XCTUnwrap(URL(string: "https://github.com/example/DroidHub/releases/tag/v0.4.0"))
        for automatic in [false, true] {
            XCTAssertEqual(
                UpdateNotice.forResult(.updateAvailable(version: "0.4.0", page: page, isPreview: true),
                                       currentVersion: "0.3.117", includePreviews: true, automatic: automatic)?.releasePage,
                page
            )
        }
        XCTAssertNil(UpdateNotice.forResult(.upToDate, currentVersion: "0.3.117", includePreviews: true, automatic: true))
        XCTAssertNil(UpdateNotice.forResult(.noPublishedRelease, currentVersion: "0.3.117", includePreviews: false, automatic: true))
        XCTAssertNotNil(UpdateNotice.forResult(.upToDate, currentVersion: "0.3.117", includePreviews: true, automatic: false))
        XCTAssertNotNil(UpdateNotice.forResult(.noPublishedRelease, currentVersion: "0.3.117", includePreviews: false, automatic: false))
        let offline = URLError(.notConnectedToInternet)
        XCTAssertNil(UpdateNotice.forFailure(offline, automatic: true))
        XCTAssertNotNil(UpdateNotice.forFailure(offline, automatic: false))
    }
}
