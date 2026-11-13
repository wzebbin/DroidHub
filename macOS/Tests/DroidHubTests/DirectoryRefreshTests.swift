import Foundation
import XCTest
@testable import DroidHub

final class DirectoryRefreshTests: XCTestCase {
    @MainActor
    func testUploadRefreshOnlyUpdatesTheCurrentDirectoryAndDevice() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let executable = fixture.appendingPathComponent("adb")
        let script = #"""
        #!/bin/sh
        fixture=$(dirname "$0")
        case "$*" in
            devices*)
                if [ -f "$fixture/devices" ]; then cat "$fixture/devices"
                else printf 'test-phone device\n'
                fi
                ;;
            *dir=*"/sdcard/other"*) printf 'other.txt\000f\0001\000' ;;
            *dir=*"/sdcard"*)
                if [ -f "$fixture/delay" ]; then
                    touch "$fixture/reading"
                    while [ ! -f "$fixture/release" ]; do sleep 0.02; done
                    printf 'stale.txt\000f\0001\000'
                elif [ -f "$fixture/uploaded" ]; then
                    printf 'uploaded.txt\000f\0001\000'
                else
                    printf 'original.txt\000f\0001\000'
                fi
                ;;
            *) printf 'test-phone\n\n0\n' ;;
        esac
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let model = HubModel(transferStorageURL: fixture.appendingPathComponent("queue.json"))
        model.adbPath = executable.path
        await model.refreshDevices()
        try await wait { model.transfers.connection != nil }
        let connection = try XCTUnwrap(model.transfers.connection)
        model.loadFiles()
        try await wait { !model.isLoadingDirectory }
        XCTAssertEqual(model.files.map(\.name), ["original.txt"])

        let release = fixture.appendingPathComponent("release")
        defer { try? Data().write(to: release) }
        let upload = QueuedTransfer(deviceID: connection.deviceID, device: "Test phone",
                                    operation: .upload(local: executable, directory: "/sdcard",
                                                       isDirectory: false, replaceExisting: false))
        try Data().write(to: fixture.appendingPathComponent("uploaded"))
        model.transfers.didUpload?(upload, connection)
        try await wait { model.files.map(\.name) == ["uploaded.txt"] }
        XCTAssertTrue(model.hasLoadedDirectory)

        try Data().write(to: fixture.appendingPathComponent("delay"))
        model.transfers.didUpload?(upload, connection)
        try await wait { FileManager.default.fileExists(atPath: fixture.appendingPathComponent("reading").path) }
        model.loadFiles("/sdcard/other")
        try await wait { !model.isLoadingDirectory }
        try Data().write(to: release)
        XCTAssertEqual(model.path, "/sdcard/other")
        XCTAssertEqual(model.files.map(\.name), ["other.txt"])
        XCTAssertTrue(model.hasLoadedDirectory)

        let reading = fixture.appendingPathComponent("reading")
        try FileManager.default.removeItem(at: fixture.appendingPathComponent("delay"))
        model.loadFiles("/sdcard")
        try await wait { !model.isLoadingDirectory }
        XCTAssertEqual(model.files.map(\.name), ["uploaded.txt"])
        try FileManager.default.removeItem(at: reading)
        try FileManager.default.removeItem(at: release)
        try Data().write(to: fixture.appendingPathComponent("delay"))
        model.transfers.didUpload?(upload, connection)
        try await wait { FileManager.default.fileExists(atPath: reading.path) }
        try Data("replacement-phone device\n".utf8).write(to: fixture.appendingPathComponent("devices"))
        await model.refreshDevices()
        try Data().write(to: release)
        try await wait { model.transfers.connection?.serial == "replacement-phone" }
        XCTAssertTrue(model.files.isEmpty)
        XCTAssertFalse(model.hasLoadedDirectory)
        await model.shutdown()
    }

    @MainActor
    private func wait(for condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw CocoaError(.fileReadUnknown)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
