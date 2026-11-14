import XCTest
import DroidHubCore
@testable import DroidHub

@MainActor
final class BatchMoveIntegrationTests: XCTestCase {
    func testBatchMoveOnUSBAndWiFi() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let adb = env["DROIDHUB_BATCH_MOVE_QA_ADB"], let phoneRoot = env["DROIDHUB_BATCH_MOVE_QA_ROOT"],
              let usb = env["DROIDHUB_BATCH_MOVE_QA_USB"], let wifi = env["DROIDHUB_BATCH_MOVE_QA_WIFI"] else {
            throw XCTSkip("No explicit batch move fixture")
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        for (label, serial) in [("USB", usb), ("Wi-Fi", wifi)] {
            let qa = root.appendingPathComponent(label)
            try manager.createDirectory(at: qa, withIntermediateDirectories: true)
            let wrapper = qa.appendingPathComponent("adb")
            let script = #"""
            #!/bin/sh
            cd "$(dirname "$0")" || exit 1
            adb=\#(Shell.quote(adb))
            if [ -f offline ]; then
                if [ "$1" = devices ]; then printf 'List of devices attached\n\n'; exit 0; fi
                printf 'adb: error: closed\n' >&2
                exit 1
            fi
            if [ "$3" = pull ]; then exec sleep 40; fi
            case "$7" in
                *'chmod 700 '*'02 folder'*)
                    if [ -f interrupt ]; then
                        mode=$(cat interrupt)
                        rm interrupt
                        if [ "$mode" = after ]; then "$adb" "$@" > move-result || exit $?; fi
                        touch offline
                        printf 'adb: error: closed\n' >&2
                        exit 1
                    fi ;;
            esac
            exec "$adb" "$@"
            """#
            try Data(script.utf8).write(to: wrapper)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
            let storage = qa.appendingPathComponent("queue.json")
            let model = HubModel(transferStorageURL: storage)
            model.adbPath = wrapper.path

            func phone(_ command: String) async throws -> String {
                let data = try await ProcessRunner.run(adb, ["-s", serial, "shell", "-T", "sh", "-c", Shell.quote(command)])
                return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
            }
            func connect(_ model: HubModel) async throws {
                await model.refreshDevices()
                model.selectedSerial = serial
                try await wait { model.transfers.connection?.serial == serial }
            }
            func open(_ directory: String) async throws -> HubModel.UploadTarget {
                model.loadFiles(directory)
                try await wait { !model.busy && !model.isLoadingDirectory }
                let target = try XCTUnwrap(model.uploadTarget)
                XCTAssertEqual(target.directory, directory)
                return target
            }
            let names = ["01 文件.txt", "02 folder", "03 最后.jpg"]
            func makeFixture(_ mode: String) async throws -> (String, String) {
                let base = phoneRoot + "/" + label + "/" + mode
                let source = base + "/源"
                let destination = base + "/目标"
                _ = try await phone("set -e; mkdir -p -- \(Shell.quote(source + "/02 folder/nested/empty")) \(Shell.quote(destination)); "
                    + "printf alpha > \(Shell.quote(source + "/01 文件.txt")); "
                    + "printf beta > \(Shell.quote(source + "/02 folder/nested/item.txt")); "
                    + "printf gamma > \(Shell.quote(source + "/03 最后.jpg"))")
                return (source, destination)
            }
            func selection() throws -> [DeviceFile] {
                try names.map { name in try XCTUnwrap(model.files.first { $0.name == name }) }
            }

            try await connect(model)
            XCTAssertEqual(model.selectedDevice?.isWireless, label == "Wi-Fi")
            let (source, destination) = try await makeFixture("normal")
            let target = try await open(source)
            let selected = try selection()
            let alias = source.replacingOccurrences(of: "/sdcard/", with: "/storage/emulated/0/")
            let nested = try await model.previewBatchMove(selected, to: alias + "/02 folder/nested", in: target)
            XCTAssertTrue(nested[1].issue?.contains("自身或子目录") == true)
            let same = try await model.previewBatchMove(selected, to: alias, in: target)
            XCTAssertTrue(same.allSatisfy { $0.issue?.contains("其他目标目录") == true })
            let cross = try await model.previewBatchMove(selected, to: "/data/local/tmp", in: target)
            XCTAssertTrue(cross.allSatisfy { $0.issue?.contains("同一存储卷") == true })

            let clean = try await model.previewBatchMove(selected, to: destination, in: target)
            XCTAssertEqual(clean.compactMap(\.move).count, 3)
            XCTAssertTrue(clean.allSatisfy { $0.issue == nil })
            let destinationBefore = try await phone("ls -A \(Shell.quote(destination))")
            XCTAssertTrue(destinationBefore.isEmpty)
            let conflict = destination + "/01 文件.TXT"
            _ = try await phone("printf keep > \(Shell.quote(conflict))")
            let blocked = try await model.previewBatchMove(selected, to: destination, in: target)
            XCTAssertTrue(blocked[0].issue?.contains("同名") == true)
            model.startBatchMove(clean, in: target)
            try await wait { !model.busy }
            XCTAssertTrue(model.error?.contains("同名") == true)
            XCTAssertNil(model.moveBatch)
            let existing = try await phone("cat \(Shell.quote(conflict))")
            XCTAssertEqual(existing, "keep")
            _ = try await phone("rm -- \(Shell.quote(conflict))")

            let connection = try XCTUnwrap(model.transfers.connection)
            let download = QueuedTransfer(deviceID: connection.deviceID, device: label,
                operation: .download(file: selected[0], destination: qa.appendingPathComponent("hold"), replaceExisting: false))
            model.transfers.enqueue([download])
            try await wait { model.transfers.items.first?.state == .transferring }
            let active = try await model.previewBatchMove(selected, to: destination, in: target)
            XCTAssertTrue(active[0].issue?.contains("传输任务") == true)
            model.transfers.pause(download.id)
            try await wait { model.transfers.items.first?.state == .paused }
            let upload = QueuedTransfer(deviceID: connection.deviceID, device: label,
                operation: .upload(local: qa.appendingPathComponent("03 最后.JPG"), directory: destination,
                                   isDirectory: false, replaceExisting: false), state: .paused)
            model.transfers.enqueue([upload])
            let paused = try await model.previewBatchMove(selected, to: destination, in: target)
            XCTAssertTrue(paused[0].issue?.contains("传输任务") == true)
            XCTAssertTrue(paused[2].issue?.contains("传输任务") == true)
            model.error = nil
            model.startBatchMove(clean, in: target)
            try await wait { !model.busy }
            XCTAssertTrue(model.error?.contains("传输任务") == true)
            XCTAssertNil(model.moveBatch)
            model.transfers.cancel(download.id)
            model.transfers.cancel(upload.id)

            for mode in ["before", "after"] {
                let (source, destination) = try await makeFixture(mode)
                let target = try await open(source)
                let rows = try await model.previewBatchMove(try selection(), to: destination, in: target)
                try Data(mode.utf8).write(to: qa.appendingPathComponent("interrupt"))
                model.startBatchMove(rows, in: target)
                try await wait { !model.busy && model.moveBatch?.checking == true }
                XCTAssertEqual(model.moveBatch?.completed, 1)
                await model.refreshDevices()
                try await wait { model.transfers.connection == nil }
                let stored = try RemoteMoveBatchStore(url: qa.appendingPathComponent("move-batches.json")).load()
                XCTAssertEqual(stored.first?.completed, 1)
                XCTAssertTrue(stored.first?.checking == true)
                if mode == "after", env["DROIDHUB_BATCH_MOVE_QA_RECONNECT"] == "1" {
                    let client = ADBClient(executable: adb)
                    let devices = try await client.devices()
                    let transport = try XCTUnwrap(devices.first { $0.serial == serial }?.transportID)
                    if label == "Wi-Fi" {
                        _ = try await ProcessRunner.run(adb, ["disconnect", serial], timeout: 5)
                        _ = try await ProcessRunner.run(adb, ["connect", serial], timeout: 10)
                    } else {
                        _ = try await ProcessRunner.run(adb, ["-s", serial, "reconnect"], timeout: 5)
                    }
                    var reconnected = false
                    for _ in 0..<15 {
                        let current = try await client.devices()
                        if current.contains(where: { $0.serial == serial && $0.isOnline && $0.transportID != transport }) {
                            reconnected = true
                            break
                        }
                        try await Task.sleep(for: .seconds(1))
                    }
                    XCTAssertTrue(reconnected, "The real \(label) ADB transport did not reconnect")
                    if reconnected { print("Verified \(label) real ADB transport reconnected") }
                }
                try manager.removeItem(at: qa.appendingPathComponent("offline"))
                // A second model in the after case also exercises app restart with an interrupted batch.
                let resumed = mode == "before" ? model : HubModel(transferStorageURL: storage)
                resumed.adbPath = wrapper.path
                try await connect(resumed)
                try await wait { resumed.canManageMoveBatch && resumed.moveBatch?.checking == false }
                XCTAssertEqual(resumed.moveBatch?.completed, mode == "before" ? 1 : 2)
                XCTAssertFalse(try XCTUnwrap(resumed.moveBatch).checking)
                let retryConflict = destination + "/03 最后.jpg"
                _ = try await phone("printf conflict > \(Shell.quote(retryConflict))")
                resumed.retryBatchMove()
                try await wait { !resumed.busy }
                XCTAssertEqual(resumed.moveBatch?.completed, mode == "before" ? 1 : 2)
                XCTAssertTrue(resumed.moveBatch?.detail?.contains("同名") == true)
                _ = try await phone("rm -- \(Shell.quote(retryConflict))")
                resumed.retryBatchMove()
                try await wait { !resumed.busy }
                XCTAssertTrue(resumed.moveBatch?.isFinished == true, resumed.error ?? "")
                let content = try await phone("set -e; test -z \"$(ls -A \(Shell.quote(source)))\"; "
                    + "test -d \(Shell.quote(destination + "/02 folder/nested/empty")); "
                    + "test -z \"$(ls -A \(Shell.quote(destination + "/02 folder/nested/empty")))\"; "
                    + "cat \(Shell.quote(destination + "/01 文件.txt")) \(Shell.quote(destination + "/02 folder/nested/item.txt")) "
                    + "\(Shell.quote(destination + "/03 最后.jpg"))")
                XCTAssertEqual(content, "alphabetagamma")
                if resumed !== model { await resumed.shutdown() }
            }
            await model.shutdown()
            print("Verified \(label) batch move preview, conflict and transfer protection, interrupted move recovery and retry")
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<800 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw HubError.message("Batch move fixture timed out.")
    }
}
