import XCTest
import DroidHubCore
@testable import DroidHub

@MainActor
final class DownloadRecoveryIntegrationTests: XCTestCase {
    func testLargeDownloadResumesAndVerifiesOnPhone() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DROIDHUB_DOWNLOAD_QA_ISOLATED_SERVER"] == "1",
              let serial = env["DROIDHUB_DOWNLOAD_QA_SERIAL"], let adb = env["DROIDHUB_DOWNLOAD_QA_ADB"],
              let remote = env["DROIDHUB_DOWNLOAD_QA_DIRECTORY"] else { throw XCTSkip("No explicit download recovery fixture") }
        let client = ADBClient(executable: adb)
        let hardware = try await client.hardwareSerial(for: serial)
        let identity = TransferDeviceID.hardware(try XCTUnwrap(hardware))
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let name = "large 'binary'.bin"
        let source = root.appendingPathComponent(name)
        let phoneSource = remote + "/" + name
        _ = try await ProcessRunner.run("/bin/dd", ["if=/dev/urandom", "of=\(source.path)", "bs=1048576", "count=64"])
        _ = try await ProcessRunner.run(adb, ["-s", serial, "push", source.path, phoneSource], timeout: 120)
        let files = try await client.files(serial: serial, path: remote)
        let file = try XCTUnwrap(files.first { $0.name == name })
        XCTAssertEqual(file.size, DownloadCheckpoint.minimumSize)
        let half = file.size / 2

        for scenario in ["reconnect", "reopen", "corrupt"] {
            let fixture = root.appendingPathComponent(scenario)
            try manager.createDirectory(at: fixture, withIntermediateDirectories: true)
            let log = fixture.appendingPathComponent("offsets")
            let wrapper = fixture.appendingPathComponent("adb")
            let partialCommand = "head -c \(half) -- \(Shell.quote(phoneSource)) && sleep 45"
            let script = #"""
            #!/bin/sh
            case "$7" in
                "'tail -c +"*)
                    printf '%s\n' "$7" | awk '{print $3}' >> \#(Shell.quote(log.path))
                    if [ "$(wc -l < \#(Shell.quote(log.path)))" -eq 1 ]; then
                        exec \#(Shell.quote(adb)) -s "$2" shell -T sh -c \#(Shell.quote(Shell.quote(partialCommand)))
                    fi ;;
            esac
            exec \#(Shell.quote(adb)) "$@"
            """#
            try Data(script.utf8).write(to: wrapper)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
            let store = TransferQueueStore(url: fixture.appendingPathComponent("queue.json"))
            let model = HubModel(transferStorageURL: store.url)
            let original = model.transfers
            let destination = fixture.appendingPathComponent(name)
            let connection = TransferConnection(deviceID: identity, serial: serial, executable: wrapper.path)
            let task = QueuedTransfer(deviceID: identity, device: "Test phone",
                                      operation: .download(file: file, destination: destination, replaceExisting: false))
            let checkpoint = try XCTUnwrap(task.downloadCheckpoint)
            original.connect(connection)
            original.enqueue([task])
            do {
                try await waitUntil { original.items.first?.bytes == half || original.items.first?.state == .failed }
            } catch {
                await model.shutdown()
                throw error
            }
            guard original.items.first?.bytes == half else {
                let detail = original.items.first?.detail
                await model.shutdown()
                XCTFail("\(scenario): \(detail ?? "Expected partial download")")
                return
            }
            if scenario == "reconnect" {
                _ = try await ProcessRunner.run(adb, ["disconnect", serial])
                original.disconnect(reason: "设备已断开")
                await original.waitForActive()
                let disconnected = try await client.devices()
                XCTAssertFalse(disconnected.contains { $0.serial == serial && $0.isOnline })
                _ = try await ProcessRunner.run(adb, ["connect", serial])
                let reconnected = try await client.devices()
                XCTAssertTrue(reconnected.contains { $0.serial == serial && $0.isOnline })
            } else {
                await model.shutdown()
            }
            let interrupted = try XCTUnwrap(try store.load().first)
            XCTAssertTrue(interrupted.state == .interrupted || (scenario == "reconnect" && interrupted.state == .failed), scenario)
            XCTAssertEqual(checkpoint.savedBytes, half, scenario)
            XCTAssertFalse(manager.fileExists(atPath: destination.path), scenario)
            if scenario == "corrupt" {
                let stage = fixture.appendingPathComponent(".droidhub-resume-\(task.id.uuidString)/payload.part")
                let handle = try FileHandle(forUpdating: stage)
                let originalByte = try XCTUnwrap(handle.read(upToCount: 1)?.first)
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: Data([originalByte ^ 0xff]))
                try handle.close()
            }

            let restored = scenario == "reconnect" ? original : HubModel(transferStorageURL: store.url).transfers
            XCTAssertEqual(restored.items.first?.id, task.id)
            XCTAssertEqual(restored.items.first?.bytes, half, scenario)
            restored.connect(connection)
            XCTAssertEqual(restored.retryableUnfinishedCount, 1)
            restored.retryUnfinished()
            try await waitUntil { restored.items.first?.state.isInQueue == false }
            XCTAssertEqual(try String(contentsOf: log, encoding: .utf8).split(whereSeparator: \.isNewline),
                           ["+1", "+\(half + 1)"], scenario)
            if scenario == "corrupt" {
                XCTAssertEqual(restored.items.first?.state, .failed)
                XCTAssertTrue(restored.items.first?.detail?.contains("完整性校验失败") == true)
                XCTAssertFalse(manager.fileExists(atPath: destination.path))
                XCTAssertEqual(checkpoint.savedBytes, 0)
                restored.retryUnfinished()
                try await waitUntil { restored.items.first?.state.isInQueue == false }
                XCTAssertEqual(try String(contentsOf: log, encoding: .utf8).split(whereSeparator: \.isNewline).last, "+1")
            }
            await restored.flushPersistence()
            XCTAssertEqual(restored.items.first?.state, .completed, restored.items.first?.detail ?? scenario)
            XCTAssertEqual(try store.load().first?.state, .completed)
            XCTAssertTrue(manager.contentsEqual(atPath: destination.path, andPath: source.path), scenario)
            XCTAssertFalse(try manager.contentsOfDirectory(atPath: fixture.path).contains { $0.hasPrefix(".droidhub-resume-") })
            print("Verified large download \(scenario): saved \(half) bytes, resumed at \(half + 1), checked SHA-256 and final contents")
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<2400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw HubError.message("Download test did not reach the expected state.")
    }

    func testDownloadRecoveryOnPhone() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DROIDHUB_DOWNLOAD_QA_ISOLATED_SERVER"] == "1",
              let serial = env["DROIDHUB_DOWNLOAD_QA_SERIAL"], let adb = env["DROIDHUB_DOWNLOAD_QA_ADB"],
              let remote = env["DROIDHUB_DOWNLOAD_QA_DIRECTORY"] else { throw XCTSkip("No explicit download recovery fixture") }
        let client = ADBClient(executable: adb)
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let hardware = try await client.hardwareSerial(for: serial)
        let identity = TransferDeviceID.hardware(try XCTUnwrap(hardware))
        let bytes = Data((0..<8192).map { UInt8($0 % 251) })
        let metadata = Data("nested fixture\n".utf8)
        let prefix = root.appendingPathComponent("prefix.bin")
        let payload = root.appendingPathComponent("payload.bin")
        try bytes.prefix(4096).write(to: prefix)
        try bytes.write(to: payload)
        let remotePrefix = remote + "/prefix.bin"
        _ = try await ProcessRunner.run(adb, ["-s", serial, "push", prefix.path, remotePrefix])

        let name = "source file.bin"
        let phoneSource = remote + "/" + name
        _ = try await ProcessRunner.run(adb, ["-s", serial, "push", payload.path, phoneSource])
        let remoteFiles = try await client.files(serial: serial, path: remote)
        let file = try XCTUnwrap(remoteFiles.first { $0.name == name })

        for reopen in [false, true] {
            let label = "file" + (reopen ? "-reopen" : "-reconnect")
            let fixture = root.appendingPathComponent(label)
            let output = fixture.appendingPathComponent("output")
            try manager.createDirectory(at: output, withIntermediateDirectories: true)
            let wrapper = fixture.appendingPathComponent("adb")
            let script = #"""
            #!/bin/sh
            cd "$(dirname "$0")" || exit 1
            shift 2
            if [ "$1" = pull ] && [ ! -f started ]; then
                touch started || exit 1
                \#(Shell.quote(adb)) -s \#(Shell.quote(serial)) pull \#(Shell.quote(remotePrefix)) "$3" || exit 1
                exec sleep 30
            fi
            exec \#(Shell.quote(adb)) -s \#(Shell.quote(serial)) "$@"
            """#
            try Data(script.utf8).write(to: wrapper)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
            let store = TransferQueueStore(url: fixture.appendingPathComponent("queue.json"))
            let model = HubModel(transferStorageURL: store.url)
            let original = model.transfers
            let destination = output.appendingPathComponent(name)
            let id = UUID()
            original.connect(TransferConnection(deviceID: identity, serial: "192.0.2.2:40001", executable: wrapper.path))
            original.enqueue([QueuedTransfer(id: id, deviceID: identity, device: "Test phone",
                                              operation: .download(file: file, destination: destination, replaceExisting: false))])
            for _ in 0..<240 where original.items.first?.bytes != 4096 {
                try await Task.sleep(for: .milliseconds(25))
            }
            let transferred = original.items.first?.bytes
            if transferred != 4096 {
                await model.shutdown()
            }
            XCTAssertEqual(transferred, 4096, label)
            guard transferred == 4096 else { continue }
            XCTAssertFalse(manager.fileExists(atPath: destination.path), label)
            XCTAssertEqual(try manager.contentsOfDirectory(atPath: output.path).count, 1, label)

            if reopen {
                await model.shutdown()
            } else {
                _ = try await ProcessRunner.run(adb, ["disconnect", serial])
                original.disconnect(reason: "设备已断开")
                await original.waitForActive()
                let disconnected = try await client.devices()
                XCTAssertFalse(disconnected.contains { $0.serial == serial && $0.isOnline }, label)
                _ = try await ProcessRunner.run(adb, ["connect", serial])
                let reconnected = try await client.devices()
                XCTAssertTrue(reconnected.contains { $0.serial == serial && $0.isOnline }, label)
            }
            XCTAssertEqual(try store.load().first?.state, .interrupted, label)
            XCTAssertTrue(try manager.contentsOfDirectory(atPath: output.path).isEmpty, label)

            let otherStage = ".droidhub-download-\(UUID().uuidString).part"
            try metadata.write(to: output.appendingPathComponent(otherStage))
            try metadata.write(to: destination)

            let queue = reopen ? HubModel(transferStorageURL: store.url).transfers : original
            XCTAssertEqual(queue.items.first?.id, id, label)
            XCTAssertEqual(queue.items.first?.state, .interrupted, label)
            queue.connect(TransferConnection(deviceID: identity, serial: "192.0.2.2:40002", executable: wrapper.path))
            XCTAssertEqual(queue.retryableUnfinishedCount, 1, label)
            queue.retryUnfinished()
            for _ in 0..<400 where queue.items.first?.state.isInQueue == true {
                try await Task.sleep(for: .milliseconds(25))
            }
            let item = try XCTUnwrap(queue.items.first)
            XCTAssertEqual(item.state, .completed, "\(label): \(item.detail ?? "")")
            await queue.flushPersistence()
            XCTAssertEqual(try store.load().first?.state, .completed, label)
            let result = try XCTUnwrap(item.downloadDestination)
            XCTAssertNotEqual(result.path, destination.path, label)
            XCTAssertEqual(try Data(contentsOf: result), bytes, label)
            XCTAssertEqual(try Data(contentsOf: destination), metadata, label)
            XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(otherStage)), metadata, label)
            XCTAssertEqual(Set(try manager.contentsOfDirectory(atPath: output.path)), [name, otherStage, result.lastPathComponent], label)
            print("Verified download \(label): interrupted at 4096 bytes, retried, verified contents, directory tree, and staging cleanup")
        }
    }
}
