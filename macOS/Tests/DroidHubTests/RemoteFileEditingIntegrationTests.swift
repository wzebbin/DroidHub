import XCTest
import AppKit
import SwiftUI
import DroidHubCore
@testable import DroidHub

@MainActor
final class RemoteFileEditingIntegrationTests: XCTestCase {
    func testFileEditingOnUSBAndWiFi() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let adb = env["DROIDHUB_EDIT_QA_ADB"], let remote = env["DROIDHUB_EDIT_QA_ROOT"],
              let protected = env["DROIDHUB_EDIT_QA_READONLY"],
              let usb = env["DROIDHUB_EDIT_QA_USB"], let wifi = env["DROIDHUB_EDIT_QA_WIFI"] else {
            throw XCTSkip("No explicit file-editing fixture")
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let wrapper = root.appendingPathComponent("adb")
        let script = #"""
        #!/bin/sh
        if [ "$3" = pull ]; then exec sleep 40; fi
        exec \#(Shell.quote(adb)) "$@"
        """#
        try Data(script.utf8).write(to: wrapper)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let source = root.appendingPathComponent("原始 文件.TXT")
        let payload = Data("DroidHub file editing fixture\n".utf8)
        try payload.write(to: source)
        let suite = "DroidHub-File-Editing-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        for (label, serial) in [("USB", usb), ("Wi-Fi", wifi)] {
            let model = HubModel(transferStorageURL: root.appendingPathComponent(label + ".json"),
                                 transferPreferences: preferences)
            model.adbPath = wrapper.path
            await model.refreshDevices()
            model.selectedSerial = serial
            try await wait { model.transfers.connection?.serial == serial }
            let connection = try XCTUnwrap(model.transfers.connection)
            XCTAssertEqual(model.selectedDevice?.isWireless, label == "Wi-Fi")
            let parent = remote + "/" + label
            model.loadFiles(parent)
            try await wait { !model.busy && !model.isLoadingDirectory }
            XCTAssertEqual(model.path, parent)

            let folderName = "新建 文件 '一'"
            var selected: DeviceFile?
            model.editRemoteFile(nil, name: folderName, in: try XCTUnwrap(model.uploadTarget)) { selected = $0 }
            try await wait { !model.busy }
            let folder = try XCTUnwrap(selected, model.error ?? "")
            XCTAssertTrue(folder.isDirectory)
            XCTAssertEqual(folder.name, folderName)
            model.editRemoteFile(nil, name: folderName, in: try XCTUnwrap(model.uploadTarget)) { _ in XCTFail("Duplicate creation succeeded") }
            try await wait { !model.busy }
            XCTAssertTrue(model.error?.contains("同名") == true)

            model.error = nil
            model.loadFiles(folder.path)
            try await wait { !model.busy && !model.isLoadingDirectory }
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            XCTAssertTrue(pasteboard.writeObjects([source as NSURL]))
            let dropArea = FinderDropArea<EmptyView>.Host(rootView: EmptyView())
            dropArea.target = try XCTUnwrap(model.uploadTarget)
            dropArea.accept = { urls, target in XCTAssertTrue(model.enqueueUploads(urls, to: target)) }
            XCTAssertTrue(dropArea.acceptFileDrop(from: pasteboard, operations: .copy))
            try await wait { model.transfers.items.first?.state == .completed || model.transfers.items.first?.state == .failed }
            XCTAssertEqual(model.transfers.items.first?.state, .completed, model.transfers.items.first?.detail ?? "")
            model.loadFiles()
            try await wait { !model.busy && !model.isLoadingDirectory }
            let file = try XCTUnwrap(model.files.first { $0.name == source.lastPathComponent })
            model.editRemoteFile(file, name: "改名 文件.txt", in: try XCTUnwrap(model.uploadTarget)) { selected = $0 }
            try await wait { !model.busy }
            let renamed = try XCTUnwrap(selected)
            XCTAssertEqual(renamed.name, "改名 文件.TXT")
            XCTAssertFalse(model.files.contains { $0.id == file.id })
            let downloaded = root.appendingPathComponent(label + "-readback")
            try await ADBClient(executable: adb).download(serial: serial, remote: renamed.path, local: downloaded)
            XCTAssertEqual(try Data(contentsOf: downloaded), payload)

            model.editRemoteFile(nil, name: "占用.TXT", in: try XCTUnwrap(model.uploadTarget)) { _ in }
            try await wait { !model.busy }
            model.editRemoteFile(renamed, name: "占用", in: try XCTUnwrap(model.uploadTarget)) { _ in XCTFail("Duplicate rename succeeded") }
            try await wait { !model.busy }
            XCTAssertTrue(model.error?.contains("同名") == true)
            XCTAssertTrue(model.files.contains { $0.id == renamed.id })

            model.error = nil
            model.loadFiles(parent)
            try await wait { !model.busy && !model.isLoadingDirectory }
            let aliased = try await connection.client.files(serial: serial,
                path: folder.path.replacingOccurrences(of: "/sdcard/", with: "/storage/emulated/0/"))
            let download = try XCTUnwrap(aliased.first { $0.name == renamed.name })
            let task = QueuedTransfer(deviceID: connection.deviceID, device: label,
                operation: .download(file: download, destination: root.appendingPathComponent(label + "-pending"), replaceExisting: false))
            model.transfers.enqueue([task])
            for state: QueuedTransfer.State in [.transferring, .paused] {
                try await wait { model.transfers.items.first(where: { $0.id == task.id })?.state == state }
                model.editRemoteFile(folder, name: "受保护", in: try XCTUnwrap(model.uploadTarget)) { _ in XCTFail("Active path renamed") }
                try await wait { !model.busy }
                XCTAssertTrue(model.error?.contains("传输任务") == true, model.error ?? "")
                model.error = nil
                if state == .transferring { model.transfers.pause(task.id) }
            }
            model.transfers.cancel(task.id)
            model.editRemoteFile(folder, name: "改名 目录.v2", in: try XCTUnwrap(model.uploadTarget)) { selected = $0 }
            try await wait { !model.busy }
            XCTAssertEqual(selected?.name, "改名 目录.v2", model.error ?? "")

            let checkpointID = UUID()
            let stage = ADBClient.uploadFolderStagingPath(directory: parent, id: checkpointID)
            let stageName = (stage as NSString).lastPathComponent
            try await connection.client.createDirectory(serial: serial, parent: parent, name: stageName)
            model.loadFiles()
            try await wait { !model.busy && !model.isLoadingDirectory }
            let stagedFolder = try XCTUnwrap(model.files.first { $0.path == stage })
            var pausedUpload = QueuedTransfer(deviceID: connection.deviceID, device: label,
                operation: .upload(local: root, directory: parent, isDirectory: true, replaceExisting: false),
                state: .paused)
            pausedUpload.uploadResumeID = checkpointID
            model.transfers.enqueue([pausedUpload])
            model.editRemoteFile(stagedFolder, name: "试图改名", in: try XCTUnwrap(model.uploadTarget)) { _ in XCTFail("Checkpoint renamed") }
            try await wait { !model.busy }
            XCTAssertTrue(model.error?.contains("传输任务") == true, model.error ?? "")
            model.transfers.cancel(pausedUpload.id)
            try await wait { model.transfers.items.first(where: { $0.id == pausedUpload.id })?.uploadResumeID == nil }
            model.error = nil

            model.loadFiles(protected)
            try await wait { !model.busy && !model.isLoadingDirectory }
            let readOnly = try XCTUnwrap(model.files.first { $0.name == "readonly.txt" })
            model.editRemoteFile(readOnly, name: "禁止修改", in: try XCTUnwrap(model.uploadTarget)) { _ in XCTFail("Read-only file renamed") }
            try await wait { !model.busy }
            XCTAssertTrue(model.error?.contains("没有权限") == true, model.error ?? "")
            model.error = nil
            model.editRemoteFile(nil, name: "禁止新建", in: try XCTUnwrap(model.uploadTarget)) { _ in XCTFail("Read-only directory allowed creation") }
            try await wait { !model.busy }
            XCTAssertTrue(model.error?.contains("没有权限") == true, model.error ?? "")
            await model.shutdown()
            print("Verified \(label) file editing, AppKit file drop, path conflicts and permissions")
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw HubError.message("File-editing fixture timed out.")
    }
}
