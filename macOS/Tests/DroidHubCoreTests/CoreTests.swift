import XCTest
@testable import DroidHubCore

final class CoreTests: XCTestCase {
    func testDeviceAuthorizationStates() {
        let devices = AndroidDevice.parse("List of devices attached\nABC device product:p model:Pixel_8 transport_id:1\nDEF unauthorized usb:1\nGHI offline\n")
        XCTAssertEqual(devices.count, 3)
        XCTAssertEqual(devices[0].model, "Pixel 8")
        XCTAssertFalse(devices[1].isOnline)
        XCTAssertFalse(devices[2].isOnline)
    }

    func testNullDelimitedNamesAndDirectoryOrder() throws {
        let data = Data("a\nb.jpg\0f\012\0Folder\0d\00\0".utf8)
        let files = try DeviceFile.parse(data, directory: "/sdcard")
        XCTAssertEqual(files.first?.name, "Folder")
        XCTAssertEqual(files.last?.name, "a\nb.jpg")
        XCTAssertEqual(files.last?.size, 12)
    }

    func testMalformedDirectoryIsRejected() {
        XCTAssertThrowsError(try DeviceFile.parse(Data("file\0f".utf8), directory: "/"))
    }

    func testDirectoryOrderKeepsCommonFoldersFirstAndUsesNaturalNames() throws {
        let rows = [
            ["folder10", "d", "0"], ["Movies", "f", "1"], ["Pictures", "d", "0"],
            ["folder2", "d", "0"], ["DCIM", "d", "0"], ["file2", "f", "1"]
        ]
        let data = Data((rows.flatMap { $0 }.joined(separator: "\0") + "\0").utf8)
        let files = try DeviceFile.parse(data, directory: "/sdcard")
        XCTAssertEqual(files.map(\.name), ["DCIM", "Pictures", "folder2", "folder10", "file2", "Movies"])
        XCTAssertTrue(files.prefix(4).allSatisfy(\.isDirectory))
    }

    func testShellQuoteDoesNotEvaluateMetacharacters() async throws {
        let value = "a'b $(printf unsafe) `id`\nnext"
        let result = try await ProcessRunner.run("/bin/sh", ["-c", "printf '%s' " + Shell.quote(value)])
        XCTAssertEqual(String(decoding: result, as: UTF8.self), value)
    }

    func testDirectoryScriptHandlesHostileNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "a'b $x\nphoto.jpg"
        try Data("hi".utf8).write(to: root.appendingPathComponent(name))
        // macOS stat differs from Android toybox; names and framing remain testable.
        let script = try Shell.directoryScript(root.path)
        let data = try await ProcessRunner.run("/bin/sh", ["-c", script])
        let files = try DeviceFile.parse(data, directory: root.path)
        XCTAssertEqual(files.map(\.name), [name])
    }

    func testRealDeviceDirectoryWhenRequested() async throws {
        guard let serial = ProcessInfo.processInfo.environment["DROIDHUB_TEST_SERIAL"],
              let executable = ADBClient.discover("adb") else { throw XCTSkip("No explicit test device selected") }
        let client = ADBClient(executable: executable)
        let devices = try await client.devices()
        XCTAssertTrue(devices.contains { $0.serial == serial && $0.isOnline })
        _ = try await client.files(serial: serial, path: "/sdcard")
        do {
            _ = try await client.files(serial: serial, path: "/droidhub-nonexistent-\(UUID().uuidString)")
            XCTFail("Expected a remote directory error")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }
}
