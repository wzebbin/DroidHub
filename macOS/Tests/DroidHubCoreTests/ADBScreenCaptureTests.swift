import Foundation
import ImageIO
import XCTest
@testable import DroidHubCore

final class ADBScreenCaptureTests: XCTestCase {
    func testRejectsNonImageOutputBeforeCreatingDestination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await ADBClient(executable: "/bin/echo").saveScreenshot(serial: "fixture", in: directory)
            XCTFail("Non-image output should not be saved")
        } catch let error as HubError {
            XCTAssertTrue(error.localizedDescription.contains("PNG"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testSavesCompleteDistinctPNGsOnPhone() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let executable = env["DROIDHUB_SCREEN_TEST_ADB"], let serial = env["DROIDHUB_SCREEN_TEST_SERIAL"] else {
            throw XCTSkip("No screenshot device configured")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = ADBClient(executable: executable)
        let first = try await client.saveScreenshot(serial: serial, in: directory)
        let second = try await client.saveScreenshot(serial: serial, in: directory)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       Set([first.lastPathComponent, second.lastPathComponent]))
        for image in [first, second] {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(image as CFURL, nil))
            let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
        }
    }
}
