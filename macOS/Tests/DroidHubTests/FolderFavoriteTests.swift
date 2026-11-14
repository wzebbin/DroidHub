import Foundation
import XCTest
@testable import DroidHub

final class FolderFavoriteTests: XCTestCase {
    @MainActor
    func testFavoritesFollowHardwareAcrossTransportsAndAppRestarts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let suite = "DroidHub.FolderFavoriteTests." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let executable = directory.appendingPathComponent("adb")
        let script = #"""
        #!/bin/sh
        case "$*" in
            devices*) printf 'usb-phone device transport_id:1\n192.0.2.1:37000 device transport_id:2\nother-phone device transport_id:3\n192.0.2.2:37000 device transport_id:4\n' ;;
            *dir=*Missing*) printf 'Missing folder\n' >&2; exit 1 ;;
            *dir=*) exit 0 ;;
            *getprop* )
                case "$*" in
                    *'-t 3'*) printf 'different-hardware\n\n0\n' ;;
                    *'-t 4'*) printf '\n\n0\n' ;;
                    *) printf 'same-hardware\n\n0\n' ;;
                esac
                ;;
        esac
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        func makeModel() -> HubModel {
            let model = HubModel(transferStorageURL: directory.appendingPathComponent("queue.json"),
                                 transferPreferences: preferences)
            model.adbPath = executable.path
            return model
        }

        let first = makeModel()
        await first.refreshDevices()
        first.selectedSerial = "usb-phone"
        try await wait { first.transfers.connection?.serial == "usb-phone" }
        XCTAssertFalse(first.canFavoriteCurrentFolder)
        let folder = "/sdcard/Download"
        first.loadFiles(folder)
        try await wait { first.canFavoriteCurrentFolder }
        first.toggleCurrentFolderFavorite()
        XCTAssertEqual(first.favoriteFolders, [folder])
        let uploadTarget = try XCTUnwrap(first.uploadTarget)
        first.loadFiles("/sdcard/Missing")
        try await wait { first.directoryFailure != nil && !first.isLoadingDirectory }
        XCTAssertEqual(first.path, folder)
        XCTAssertNil(first.uploadTarget)
        XCTAssertFalse(first.enqueueUploads([executable], to: uploadTarget))
        first.loadFiles()
        try await wait { first.uploadTarget != nil }

        let wifi = "192.0.2.1:37000"
        first.selectedSerial = wifi
        try await wait { first.transfers.connection?.serial == wifi }
        XCTAssertEqual(first.favoriteFolders, [folder])

        first.selectedSerial = "other-phone"
        try await wait { first.transfers.connection?.serial == "other-phone" }
        XCTAssertTrue(first.favoriteFolders.isEmpty)

        let unrecognizedWiFi = "192.0.2.2:37000"
        first.selectedSerial = unrecognizedWiFi
        try await wait { first.transfers.connection?.serial == unrecognizedWiFi }
        first.loadFiles(folder)
        try await wait { first.hasLoadedDirectory }
        XCTAssertFalse(first.canFavoriteCurrentFolder)
        XCTAssertTrue(first.favoriteFolders.isEmpty)
        await first.shutdown()

        let reopened = makeModel()
        await reopened.refreshDevices()
        reopened.selectedSerial = wifi
        try await wait { reopened.transfers.connection?.serial == wifi }
        XCTAssertEqual(reopened.favoriteFolders, [folder])
        reopened.removeFolderFavorite(folder)
        reopened.selectedSerial = "usb-phone"
        try await wait { reopened.transfers.connection?.serial == "usb-phone" }
        XCTAssertTrue(reopened.favoriteFolders.isEmpty)
        await reopened.shutdown()
    }

    @MainActor
    private func wait(for condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
