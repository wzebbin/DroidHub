import Foundation
import XCTest
@testable import DroidHub

final class DeviceSelectionTests: XCTestCase {
    @MainActor
    func testRefreshSelectsOnlineTransportWhenPreviousAddressIsStillListedOffline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let list = directory.appendingPathComponent("devices.txt")
        let executable = directory.appendingPathComponent("adb")
        let script = #"""
        #!/bin/sh
        if [ "$1" = devices ]; then
            /bin/cat "$(dirname "$0")/devices.txt"
        else
            printf 'test-phone\n\n0\n'
        fi
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let oldAddress = "192.0.2.10:5555"
        let newAddress = "192.0.2.10:5556"
        try Data("\(oldAddress) device transport_id:1\n".utf8).write(to: list)
        let model = HubModel(transferStorageURL: directory.appendingPathComponent("queue.json"))
        model.adbPath = executable.path
        await model.refreshDevices()
        XCTAssertEqual(model.onlineSerial, oldAddress)
        let oldSession = model.deviceSession

        try Data("\(oldAddress) offline transport_id:1\n\(newAddress) device transport_id:2\n".utf8).write(to: list)
        await model.refreshDevices()
        XCTAssertEqual(model.onlineSerial, newAddress)
        XCTAssertNotEqual(model.deviceSession, oldSession)

        try Data("\(oldAddress) device transport_id:3\n\(newAddress) device transport_id:2\n".utf8).write(to: list)
        await model.refreshDevices()
        XCTAssertEqual(model.onlineSerial, newAddress, "Refreshing must preserve a working selection")
        await model.shutdown()
    }
}
