import XCTest
@testable import DroidHubCore

final class GitHubReleaseTests: XCTestCase {
    func testStableReleaseUsesNumericVersionAndConfiguredRepository() throws {
        let source = try XCTUnwrap(GitHubReleaseSource(repository: "example/DroidHub"))
        let release = Data(#"{"tag_name":"v0.3.100","draft":false,"prerelease":false,"html_url":"https://example.com"}"#.utf8)
        let page = try XCTUnwrap(URL(string: "https://github.com/example/DroidHub/releases/tag/v0.3.100"))
        XCTAssertEqual(try source.result(data: release, status: 200, currentVersion: "0.3.53"),
                       .updateAvailable(version: "0.3.100", page: page))
        XCTAssertEqual(try source.result(data: release, status: 200, currentVersion: "0.3.100"), .upToDate)
        XCTAssertEqual(try source.result(data: release, status: 200, currentVersion: "0.4.0"), .upToDate)
    }

    func testNoReleaseAndInvalidResponseAreDistinct() throws {
        let source = try XCTUnwrap(GitHubReleaseSource(repository: "example/DroidHub"))
        let preview = Data(#"{"tag_name":"v0.4.0-beta","draft":false,"prerelease":true}"#.utf8)
        XCTAssertEqual(try source.result(data: Data(), status: 404, currentVersion: "0.3.53"), .noPublishedRelease)
        XCTAssertEqual(try source.result(data: preview, status: 200, currentVersion: "0.3.53"), .noPublishedRelease)
        XCTAssertThrowsError(try source.result(data: Data(), status: 429, currentVersion: "0.3.53"))
        XCTAssertThrowsError(try source.result(data: Data(), status: 200, currentVersion: "0.3.53"))
        XCTAssertNil(GitHubReleaseSource(repository: "example/../other"))
    }
}
