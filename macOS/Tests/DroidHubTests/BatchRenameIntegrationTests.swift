import XCTest
import DroidHubCore
@testable import DroidHub

@MainActor
final class BatchRenameIntegrationTests: XCTestCase {
    func testPreviewAndBatchRenameOnUSBAndWiFi() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let adb = env["DROIDHUB_RENAME_QA_ADB"], let remote = env["DROIDHUB_RENAME_QA_ROOT"],
              let usb = env["DROIDHUB_RENAME_QA_USB"], let wifi = env["DROIDHUB_RENAME_QA_WIFI"] else {
            throw XCTSkip("No explicit batch rename fixture")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for (label, serial) in [("USB", usb), ("Wi-Fi", wifi)] {
            let model = HubModel(transferStorageURL: root.appendingPathComponent(label).appendingPathComponent("queue.json"))
            model.adbPath = adb
            let directory = remote + "/" + label
            func phone(_ command: String) async throws -> String {
                let data = try await ProcessRunner.run(adb, ["-s", serial, "shell", "-T", "sh", "-c", Shell.quote(command)])
                return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
            }
            let originals = ["ab.TXT", "aab.TXT", "图片.JpG", "目录.v1"]
            _ = try await phone("set -e; mkdir -p \(Shell.quote(directory + "/目录.v1/empty")); "
                + "printf one > \(Shell.quote(directory + "/ab.TXT")); "
                + "printf two > \(Shell.quote(directory + "/aab.TXT")); "
                + "printf image > \(Shell.quote(directory + "/图片.JpG")); "
                + "printf nested > \(Shell.quote(directory + "/目录.v1/content.txt"))")
            await model.refreshDevices()
            model.selectedSerial = serial
            try await wait { model.uploadTarget?.serial == serial }
            XCTAssertEqual(model.selectedDevice?.isWireless, label == "Wi-Fi")
            model.loadFiles(directory)
            try await wait { !model.busy && !model.isLoadingDirectory }
            let target = try XCTUnwrap(model.uploadTarget)
            let snapshot = try await model.batchRenameDirectory(in: target)
            let selected = originals.compactMap { name in snapshot.first { $0.name == name } }
            XCTAssertEqual(selected.count, originals.count)
            let collision = BatchRenamePlan(selection: Array(selected.prefix(2)), directory: snapshot,
                                            rule: .replace(find: "a", replacement: ""))
            XCTAssertEqual(collision.rows.map(\.issue), [.duplicateResult, .duplicateResult])

            let rule = BatchRenameRule.affixes(prefix: "归档 ", suffix: " 完成")
            let preview = BatchRenamePlan(selection: selected, directory: snapshot, rule: rule)
            XCTAssertTrue(preview.canApply)
            XCTAssertEqual(preview.rows.map(\.name), ["归档 ab 完成.TXT", "归档 aab 完成.TXT", "归档 图片 完成.JpG", "归档 目录.v1 完成"])
            let unchanged = try await model.batchRenameDirectory(in: target)
            XCTAssertEqual(unchanged, snapshot)

            // An external file can appear after the preview is visible.
            let conflict = directory + "/归档 ab 完成.txt"
            _ = try await phone("printf keep > \(Shell.quote(conflict))")
            let fresh = try await model.batchRenameDirectory(in: target)
            XCTAssertEqual(BatchRenamePlan(selection: selected, directory: fresh, rule: rule).rows.first?.issue, .existingName)
            model.batchRename(selected, rule: rule, in: target) { _ in XCTFail("Conflicting batch executed") }
            try await wait { !model.busy }
            XCTAssertTrue(model.error?.contains("同名") == true)
            let preserved = try await phone("cat \(Shell.quote(conflict))")
            XCTAssertEqual(preserved, "keep")
            let remaining = try await model.batchRenameDirectory(in: target)
            XCTAssertTrue(originals.allSatisfy { name in remaining.contains { $0.name == name } })
            _ = try await phone("rm -- \(Shell.quote(conflict))")

            let connection = try XCTUnwrap(model.transfers.connection)
            let paused = QueuedTransfer(deviceID: connection.deviceID, device: label,
                operation: .download(file: selected[0], destination: root.appendingPathComponent("paused"), replaceExisting: false),
                state: .paused)
            model.transfers.enqueue([paused])
            model.error = nil
            model.batchRename(selected, rule: rule, in: target) { _ in XCTFail("Protected batch executed") }
            try await wait { !model.busy }
            XCTAssertTrue(model.error?.contains("传输任务") == true)
            model.transfers.cancel(paused.id)

            model.error = nil
            var result: [DeviceFile] = []
            model.batchRename(selected, rule: rule, in: target) { result = $0 }
            try await wait { !model.busy }
            XCTAssertNil(model.error, model.error ?? "")
            XCTAssertEqual(Set(result.map(\.name)), Set(preview.rows.map(\.name)))
            XCTAssertEqual(Set(model.files.map(\.name)), Set(preview.rows.map(\.name)))
            XCTAssertEqual(model.batchRenameNotice, "已重命名 4 项。")
            let expected = ["one", "two", "image", "nested"]
            for (index, row) in preview.rows.enumerated() {
                let path = directory + "/" + row.name + (row.file.isDirectory ? "/content.txt" : "")
                let contents = try await phone("cat \(Shell.quote(path))")
                XCTAssertEqual(contents, expected[index])
            }
            _ = try await phone("test -d \(Shell.quote(directory + "/归档 目录.v1 完成/empty"))")
            let journal = RemoteMoveJournal(url: root.appendingPathComponent(label).appendingPathComponent("pending-moves.json"))
            XCTAssertTrue(try journal.load().isEmpty)
            await model.shutdown()
            print("Verified \(label) batch rename preview, conflicts, protected paths, extensions and contents")
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<800 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw HubError.message("Batch rename fixture timed out.")
    }
}
