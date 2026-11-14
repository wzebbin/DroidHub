import XCTest
@testable import DroidHubCore

final class GitHubReleaseTests: XCTestCase {
    func testStableReleaseUsesNumericVersionAndConfiguredRepository() throws {
        let source = try XCTUnwrap(GitHubReleaseSource(repository: "example/DroidHub"))
        let release = Data(#"{"tag_name":"v0.3.100","draft":false,"prerelease":false,"html_url":"https://example.com"}"#.utf8)
        let page = try XCTUnwrap(URL(string: "https://github.com/example/DroidHub/releases/tag/v0.3.100"))
        XCTAssertEqual(try source.result(data: release, status: 200, currentVersion: "0.3.53"),
                       .updateAvailable(version: "0.3.100", page: page, isPreview: false))
        XCTAssertEqual(try source.result(data: release, status: 200, currentVersion: "0.3.100"), .upToDate)
        XCTAssertEqual(try source.result(data: release, status: 200, currentVersion: "0.4.0"), .upToDate)
    }

    func testPreviewCheckSelectsHighestPublishedNumericVersionAndBuildsTagLink() throws {
        let source = try XCTUnwrap(GitHubReleaseSource(repository: "example/DroidHub"))
        let response = Data("""
        [
          {"tag_name":"v0.3.99","draft":false,"prerelease":false},
          {"tag_name":"v0.3.116","draft":false,"prerelease":true,"html_url":"https://example.com"},
          {"tag_name":"v0.3.115","draft":false,"prerelease":true},
          {"tag_name":"v0.4.0","draft":true,"prerelease":true},
          {"tag_name":"nightly","draft":false,"prerelease":true}
        ]
        """.utf8)
        let releases = try JSONDecoder().decode([GitHubReleaseSource.Release].self, from: response)
        let page = try XCTUnwrap(URL(string: "https://github.com/example/DroidHub/releases/tag/v0.3.116"))
        XCTAssertEqual(try source.bestResult(from: releases, currentVersion: "0.3.115"),
                       .updateAvailable(version: "0.3.116", page: page, isPreview: true))
        XCTAssertEqual(try source.bestResult(from: releases, currentVersion: "0.3.116"), .upToDate)
        XCTAssertEqual(try source.bestResult(from: releases, currentVersion: "0.4.0"), .upToDate)
        XCTAssertEqual(try source.bestResult(from: [], currentVersion: "0.3.115"), .noPublishedRelease)
        XCTAssertEqual(try source.bestResult(from: releases + [.init(tag_name: "v0.3.116", draft: false, prerelease: false)],
                                            currentVersion: "0.3.115"),
                       .updateAvailable(version: "0.3.116", page: page, isPreview: false))
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
