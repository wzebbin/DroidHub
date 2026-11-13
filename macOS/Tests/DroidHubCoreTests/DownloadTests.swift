import XCTest
@testable import DroidHubCore

final class DownloadTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func fakeADB(in root: URL, script: String) throws -> ADBClient {
        let executable = root.appendingPathComponent("adb-fixture")
        try Data(("#!/bin/sh\n" + script).utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return ADBClient(executable: executable.path)
    }

    func testProcessTimeoutStopsChildThatIgnoresTermination() async throws {
        let start = ContinuousClock.now
        do {
            _ = try await ProcessRunner.run("/bin/sh", ["-c", "trap '' TERM; exec /bin/sleep 5"], timeout: 0.2)
            XCTFail("The command exceeded its deadline")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("超时"))
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(3))
    }

    func testCancellationAfterPartialProgressRemovesStagingFile() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try fakeADB(in: root, script: #"""
        printf 'part' > "$5"
        exec sleep 30
        """#)
        let file = DeviceFile(name: "photo.png", path: "/sdcard/photo.png", isDirectory: false, size: 12)
        let destination = root.appendingPathComponent(file.name)
        let partial = expectation(description: "Reports bytes written before the transfer finishes")
        let task = Task {
            try await client.downloadFile(serial: "device", file: file, destination: destination, replaceExisting: false, progress: {
                if case .transferring(bytes: 4, total: 12) = $0 { partial.fulfill() }
            })
        }
        await fulfillment(of: [partial], timeout: 5)
        task.cancel()
        do {
            try await task.value
            XCTFail("A cancelled download must not commit")
        } catch { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["adb-fixture"])
    }

    func testFailedValidationAndUnconfirmedCollisionPreserveDestination() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try fakeADB(in: root, script: #"printf 'new' > "$5""#)
        let destination = root.appendingPathComponent("report.txt")
        try Data("old".utf8).write(to: destination)
        for (size, replace) in [(Int64(4), true), (Int64(3), false)] {
            let file = DeviceFile(name: "report.txt", path: "/sdcard/report.txt", isDirectory: false, size: size)
            do {
                try await client.downloadFile(serial: "device", file: file, destination: destination, replaceExisting: replace, progress: { _ in })
                XCTFail("Unexpected commit")
            } catch { }
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "old")
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["adb-fixture", "report.txt"])
        }
    }

    func testResumableDownloadRestartsIfSameSizeSourceChanged() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try fakeADB(in: root, script: #"""
        cd "$(dirname "$0")" || exit 1
        case "$7" in
            *stat*) printf '1:2:6:%s\n' "$(cat stamp)" ;;
            *sha256sum*) /usr/bin/shasum -a 256 < phone ;;
            "'tail -c +1 -- "*)
                if [ -e stamp-changed ]; then cat phone; else printf 'old'; exit 1; fi ;;
            *) exit 2 ;;
        esac
        """#)
        let stamp = root.appendingPathComponent("stamp")
        try Data("old".utf8).write(to: stamp)
        let file = DeviceFile(name: "document", path: "/sdcard/document", isDirectory: false, size: 6)
        let destination = root.appendingPathComponent(file.name)
        let checkpoint = DownloadCheckpoint(destination: destination, id: UUID())
        do {
            try await client.downloadFile(serial: "device", file: file, destination: destination, replaceExisting: false,
                                          checkpoint: checkpoint, progress: { _ in })
            XCTFail("A short, failed transfer must not commit")
        } catch {
            XCTAssertEqual(checkpoint.savedBytes, 3)
        }
        let replacement = Data("newest".utf8)
        try replacement.write(to: root.appendingPathComponent("phone"))
        try Data("new".utf8).write(to: stamp)
        try Data().write(to: root.appendingPathComponent("stamp-changed"))
        do {
            try await client.downloadFile(serial: "device", file: file, destination: destination, replaceExisting: false,
                                          checkpoint: checkpoint, automatic: true, progress: { _ in })
            XCTFail("Automatic resume must stop when the phone source changes")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("已变化"))
            XCTAssertEqual(checkpoint.savedBytes, 3)
        }
        try await client.downloadFile(serial: "device", file: file, destination: destination, replaceExisting: false,
                                      checkpoint: checkpoint, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: destination), replacement)
        XCTAssertEqual(checkpoint.savedBytes, 0)
    }

    func testRealADBDownloadWhenExplicitlyConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let serial = environment["DROIDHUB_TEST_SERIAL"],
              let directory = environment["DROIDHUB_PHOTO_TEST_DIRECTORY"],
              let fixture = environment["DROIDHUB_PHOTO_TEST_FILE"],
              let executable = ADBClient.discover("adb") else { throw XCTSkip("No explicit ADB file fixture") }
        let client = ADBClient(executable: executable)
        let files = try await client.files(serial: serial, path: directory)
        let file = try XCTUnwrap(files.first)
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent(file.name)
        try await client.downloadFile(serial: serial, file: file, destination: destination, replaceExisting: false, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: URL(fileURLWithPath: fixture)))
    }

    func testRealADBFolderRoundTripWhenExplicitlyConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let serial = environment["DROIDHUB_TEST_SERIAL"],
              let remote = environment["DROIDHUB_TEST_FOLDER_PARENT"],
              let executable = ADBClient.discover("adb") else { throw XCTSkip("No explicit ADB folder fixture") }
        let client = ADBClient(executable: executable)
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("照片 资料", isDirectory: true)
        let nested = source.appendingPathComponent("一层", isDirectory: true)
        try FileManager.default.createDirectory(at: nested.appendingPathComponent("空 文件夹"), withIntermediateDirectories: true)
        let contents = Data("fixture contents".utf8)
        try contents.write(to: nested.appendingPathComponent("原始 文件.txt"))
        let empty = root.appendingPathComponent("完全空目录", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        try await client.uploadFolder(serial: serial, local: source, directory: remote) { _ in }
        try await client.uploadFolder(serial: serial, local: empty, directory: remote) { _ in }
        do {
            try await client.uploadFolder(serial: serial, local: source, directory: remote) { _ in }
            XCTFail("Existing directory must not be replaced")
        } catch { }
        let remoteFiles = try await client.files(serial: serial, path: remote)
        XCTAssertEqual(Set(remoteFiles.map(\.name)), [source.lastPathComponent, empty.lastPathComponent])

        let output = root.appendingPathComponent("取回", isDirectory: true)
        try await client.downloadFolder(serial: serial, remote: remote + "/" + source.lastPathComponent, destination: output) { _ in }
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("一层/原始 文件.txt")), contents)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.appendingPathComponent("一层/空 文件夹").path), [])
        let emptyOutput = root.appendingPathComponent("取回空目录", isDirectory: true)
        try await client.downloadFolder(serial: serial, remote: remote + "/" + empty.lastPathComponent, destination: emptyOutput) { _ in }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: emptyOutput.path), [])
    }
}
