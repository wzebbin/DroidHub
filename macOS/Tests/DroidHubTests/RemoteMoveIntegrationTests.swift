import XCTest
import DroidHubCore
@testable import DroidHub

@MainActor
final class RemoteMoveIntegrationTests: XCTestCase {
    func testMoveOnUSBAndWiFi() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let adb = env["DROIDHUB_MOVE_QA_ADB"], let phoneRoot = env["DROIDHUB_MOVE_QA_ROOT"],
              let localPhoneRoot = env["DROIDHUB_MOVE_QA_LOCAL"],
              let usb = env["DROIDHUB_MOVE_QA_USB"], let wifi = env["DROIDHUB_MOVE_QA_WIFI"] else {
            throw XCTSkip("No explicit move fixture")
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let payload = "DroidHub move fixture"
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
                *'chmod 700 '*)
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
            let queue = qa.appendingPathComponent("queue.json")
            let journal = RemoteMoveJournal(url: qa.appendingPathComponent("pending-moves.json"))
            let model = HubModel(transferStorageURL: queue)
            model.adbPath = wrapper.path

            func phone(_ command: String) async throws -> String {
                let data = try await ProcessRunner.run(adb, ["-s", serial, "shell", "-T", "sh", "-c", Shell.quote(command)])
                return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
            }
            func connect() async throws {
                await model.refreshDevices()
                model.selectedSerial = serial
                try await wait { model.transfers.connection?.serial == serial && model.uploadTarget != nil }
            }
            func open(_ directory: String) async throws {
                model.loadFiles(directory)
                try await wait { !model.busy && !model.isLoadingDirectory }
                XCTAssertEqual(model.path, directory, model.error ?? "")
            }
            func file(_ name: String) throws -> DeviceFile {
                try XCTUnwrap(model.files.first { $0.name == name })
            }
            func move(_ name: String, to destination: String) async throws {
                model.error = nil
                model.moveRemoteFile(try file(name), to: destination, in: try XCTUnwrap(model.uploadTarget))
                try await wait { !model.busy }
            }
            func assertRejected(_ name: String, to destination: String, reason: String) async throws {
                try await move(name, to: destination)
                XCTAssertTrue(model.error?.contains(reason) == true, "\(label): \(model.error ?? "no error")")
                XCTAssertNotNil(model.files.first { $0.name == name })
            }

            let base = phoneRoot + "/" + label
            let a = base + "/源目录"
            let b = base + "/目标目录"
            let folderName = "嵌套 目录'一'"
            let fileName = "测试 文件.txt"
            let aFolder = a + "/" + folderName
            let bFolder = b + "/" + folderName
            let aFile = a + "/" + fileName
            let bFile = b + "/" + fileName
            let privileged = localPhoneRoot + "/" + label
            let readOnly = privileged + "/readonly"
            _ = try await phone("set -e; mkdir -p -- \(Shell.quote(aFolder + "/nested/empty")) \(Shell.quote(b)) \(Shell.quote(readOnly)); "
                + "printf %s \(Shell.quote(payload)) > \(Shell.quote(aFile)); "
                + "printf %s \(Shell.quote(payload)) > \(Shell.quote(aFolder + "/nested/item.txt")); "
                + "printf 'keep' > \(Shell.quote(bFile)); "
                + "touch \(Shell.quote(privileged + "/readme.txt")); chmod 555 \(Shell.quote(readOnly))")
            try await connect()
            XCTAssertEqual(model.selectedDevice?.isWireless, label == "Wi-Fi")
            try await open(a)
            let pickerFolders = try await model.moveDirectories(at: base, in: try XCTUnwrap(model.uploadTarget))
            XCTAssertEqual(Set(pickerFolders.map(\.name)), ["源目录", "目标目录"])
            try await assertRejected(fileName, to: b, reason: "同名")
            let kept = try await phone("cat \(Shell.quote(bFile))")
            XCTAssertEqual(kept, "keep")
            try await assertRejected(folderName, to: aFolder, reason: "自身或子目录")
            let alias = aFolder.replacingOccurrences(of: "/sdcard/", with: "/storage/emulated/0/")
            try await assertRejected(folderName, to: alias + "/nested", reason: "自身或子目录")
            try await assertRejected(fileName, to: privileged, reason: "同一存储卷")
            _ = try await phone("rm -- \(Shell.quote(bFile))")

            let connection = try XCTUnwrap(model.transfers.connection)
            let race = try await connection.client.prepareMove(serial: serial, file: file(fileName), from: a, to: b)
            _ = try await phone("printf 'new destination' > \(Shell.quote(bFile))")
            do {
                try await connection.client.applyMove(serial: serial, move: race)
                XCTFail("A destination created after preflight was overwritten")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("同名"))
            }
            let raced = try await phone("cat \(Shell.quote(bFile))")
            XCTAssertEqual(raced, "new destination")
            _ = try await phone("rm -- \(Shell.quote(bFile))")
            let download = QueuedTransfer(deviceID: connection.deviceID, device: label,
                operation: .download(file: try file(fileName), destination: qa.appendingPathComponent("hold"), replaceExisting: false))
            model.transfers.enqueue([download])
            try await wait { model.transfers.items.first?.state == .transferring }
            try await assertRejected(fileName, to: b, reason: "传输任务")
            model.transfers.pause(download.id)
            try await wait { model.transfers.items.first?.state == .paused }
            try await assertRejected(fileName, to: b, reason: "传输任务")
            model.transfers.cancel(download.id)

            let local = qa.appendingPathComponent(fileName)
            try Data(payload.utf8).write(to: local)
            let upload = QueuedTransfer(deviceID: connection.deviceID, device: label,
                operation: .upload(local: local, directory: b.replacingOccurrences(of: "/sdcard/", with: "/storage/emulated/0/"),
                                   isDirectory: false, replaceExisting: false), state: .paused)
            model.transfers.enqueue([upload])
            try await assertRejected(fileName, to: b, reason: "传输任务")
            model.transfers.cancel(upload.id)

            try await move(fileName, to: b)
            XCTAssertNil(model.error)
            XCTAssertFalse(model.files.contains { $0.name == fileName })
            let contents = try await phone("cat \(Shell.quote(bFile))")
            XCTAssertEqual(contents, payload)
            try await move(folderName, to: b)
            XCTAssertNil(model.error)
            XCTAssertFalse(model.files.contains { $0.name == folderName })
            let nested = try await phone("set -e; test ! -e \(Shell.quote(aFolder)); test -d \(Shell.quote(bFolder + "/nested/empty")); "
                + "test -z \"$(ls -A \(Shell.quote(bFolder + "/nested/empty")))\"; cat \(Shell.quote(bFolder + "/nested/item.txt"))")
            XCTAssertEqual(nested, payload)

            try await open(privileged)
            try await assertRejected("readme.txt", to: readOnly, reason: "没有权限")
            for mode in ["before", "after"] {
                let name = "断线-\(mode).txt"
                _ = try await phone("printf %s \(Shell.quote(payload)) > \(Shell.quote(a + "/" + name))")
                try await open(a)
                try Data(mode.utf8).write(to: qa.appendingPathComponent("interrupt"))
                try await move(name, to: b)
                XCTAssertEqual(try journal.load().count, 1)
                await model.refreshDevices()
                try await wait { model.transfers.connection == nil }
                model.error = nil
                model.moveNotice = nil
                try manager.removeItem(at: qa.appendingPathComponent("offline"))
                try await connect()
                let notice = try XCTUnwrap(model.moveNotice)
                XCTAssertTrue(notice.contains(mode == "after" ? "移到了目标目录" : "仍在源目录"), notice)
                XCTAssertTrue(try journal.load().isEmpty)
                let found = mode == "after" ? b : a
                let absent = mode == "after" ? a : b
                let recovered = try await phone("set -e; test ! -e \(Shell.quote(absent + "/" + name)); cat \(Shell.quote(found + "/" + name))")
                XCTAssertEqual(recovered, payload)
            }
            await model.shutdown()
            print("Verified \(label) file and folder move, guardrails and disconnect recovery before/after the syscall")
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<800 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw HubError.message("Move fixture timed out.")
    }
}
