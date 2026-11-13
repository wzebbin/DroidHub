import XCTest
import DroidHubCore
@testable import DroidHub

@MainActor
final class UploadRecoveryIntegrationTests: XCTestCase {
    func testLargeUploadResumesAndVerifiesOnPhone() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DROIDHUB_UPLOAD_QA_ISOLATED_SERVER"] == "1",
              let serial = env["DROIDHUB_UPLOAD_QA_SERIAL"], let adb = env["DROIDHUB_UPLOAD_QA_ADB"],
              let remote = env["DROIDHUB_UPLOAD_QA_DIRECTORY"] else { throw XCTSkip("No explicit upload recovery fixture") }
        let client = ADBClient(executable: adb)
        let hardware = try await client.hardwareSerial(for: serial)
        let identity = TransferDeviceID.hardware(try XCTUnwrap(hardware))
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let source = root.appendingPathComponent("large 'binary'.bin")
        let half = UploadCheckpoint.minimumSize / 2
        _ = try await ProcessRunner.run("/bin/dd", ["if=/dev/urandom", "of=\(source.path)", "bs=1048576", "count=64"])
        let reference = try await ProcessRunner.run("/usr/bin/shasum", ["-a", "256", source.path])
        let expectedHash = try XCTUnwrap(String(decoding: reference, as: UTF8.self).split(separator: " ").first)
        let input = try FileHandle(forReadingFrom: source)
        let firstByte = try XCTUnwrap(input.read(upToCount: 1)?.first)
        try input.close()

        func phone(_ command: String) async throws -> String {
            let data = try await ProcessRunner.run(adb, ["-s", serial, "shell", "-T", "sh", "-c", Shell.quote(command)], timeout: 30)
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        }

        for scenario in ["reconnect", "reopen", "corrupt"] {
            let fixture = root.appendingPathComponent(scenario)
            try manager.createDirectory(at: fixture, withIntermediateDirectories: true)
            let log = fixture.appendingPathComponent("offsets")
            let wrapper = fixture.appendingPathComponent("adb")
            let script = #"""
            #!/usr/bin/python3
            import os, sys, time
            from pathlib import Path
            adb = \#(String(reflecting: adb))
            if len(sys.argv) == 8 and 'cat 3<&9 >> "$payload"' in sys.argv[7]:
                log = Path(\#(String(reflecting: log.path)))
                first = not log.exists()
                with log.open("a") as f:
                    f.write(str(os.lseek(0, 0, os.SEEK_CUR)) + "\n")
                if first:
                    reader, writer = os.pipe()
                    parent = os.getpid()
                    if os.fork() == 0:
                        os.close(reader)
                        try:
                            remaining = \#(half)
                            while remaining:
                                data = os.read(0, min(remaining, 65536))
                                if not data:
                                    raise RuntimeError("Premature end of test fixture")
                                remaining -= len(data)
                                while data:
                                    data = data[os.write(writer, data):]
                            for _ in range(600):
                                if os.getppid() != parent:
                                    break
                                time.sleep(0.1)
                        except BrokenPipeError:
                            pass
                        finally:
                            os._exit(0)
                    os.close(writer)
                    os.dup2(reader, 0)
                    os.close(reader)
            os.execv(adb, [adb, *sys.argv[1:]])
            """#
            try Data(script.utf8).write(to: wrapper)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
            let directory = remote + "/" + scenario + "-large"
            _ = try await phone("mkdir -- \(Shell.quote(directory))")
            let store = TransferQueueStore(url: fixture.appendingPathComponent("queue.json"))
            let model = HubModel(transferStorageURL: store.url)
            let original = model.transfers
            let connection = TransferConnection(deviceID: identity, serial: serial, executable: wrapper.path)
            let task = QueuedTransfer(deviceID: identity, device: "Test phone",
                                      operation: .upload(local: source, directory: directory, isDirectory: false, replaceExisting: false))
            let stage = directory + "/.droidhub-upload-resume-\(task.id.uuidString)/payload.part"
            let destination = directory + "/" + source.lastPathComponent
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
                XCTFail("\(scenario): \(detail ?? "Expected partial upload")")
                return
            }
            if scenario == "reconnect" {
                _ = try await ProcessRunner.run(adb, ["disconnect", serial])
                original.disconnect(reason: "设备已断开")
                await original.waitForActive()
                let offline = try await client.devices()
                XCTAssertFalse(offline.contains { $0.serial == serial && $0.isOnline })
                _ = try await ProcessRunner.run(adb, ["connect", serial])
                let online = try await client.devices()
                XCTAssertTrue(online.contains { $0.serial == serial && $0.isOnline })
            } else {
                await model.shutdown()
            }
            let interrupted = try XCTUnwrap(try store.load().first)
            XCTAssertTrue(interrupted.state == .interrupted || (scenario == "reconnect" && interrupted.state == .failed))
            XCTAssertEqual(interrupted.bytes, half)
            XCTAssertEqual(interrupted.uploadResumeID, task.id)
            let partialSize = try await phone("stat -c %s -- \(Shell.quote(stage))")
            XCTAssertEqual(partialSize, String(half))
            _ = try await phone("test ! -e \(Shell.quote(destination))")
            if scenario == "corrupt" {
                let byte = String(format: "%03o", Int(firstByte ^ 0xff))
                _ = try await phone("printf '\\\(byte)' | dd of=\(Shell.quote(stage)) bs=1 count=1 conv=notrunc")
            }

            let restored = scenario == "reconnect" ? original : HubModel(transferStorageURL: store.url).transfers
            XCTAssertEqual(restored.items.first?.bytes, half)
            restored.connect(connection)
            XCTAssertEqual(restored.retryableUnfinishedCount, 1)
            restored.retryUnfinished()
            try await waitUntil { restored.items.first?.state.isInQueue == false }
            XCTAssertEqual(try String(contentsOf: log, encoding: .utf8).split(whereSeparator: \.isNewline), ["0", "\(half)"], scenario)
            if scenario == "corrupt" {
                XCTAssertEqual(restored.items.first?.state, .failed)
                XCTAssertTrue(restored.items.first?.detail?.contains("完整性校验失败") == true)
                XCTAssertEqual(restored.items.first?.bytes, 0)
                _ = try await phone("test ! -e \(Shell.quote(destination)) && test ! -e \(Shell.quote(stage))")
                restored.retryUnfinished()
                try await waitUntil { restored.items.first?.state.isInQueue == false }
                XCTAssertEqual(try String(contentsOf: log, encoding: .utf8).split(whereSeparator: \.isNewline).last, "0")
            }
            await restored.flushPersistence()
            XCTAssertEqual(restored.items.first?.state, .completed, restored.items.first?.detail ?? scenario)
            XCTAssertNil(try store.load().first?.uploadResumeID)
            let files = try await client.files(serial: serial, path: directory)
            XCTAssertEqual(files.map(\.name), [source.lastPathComponent])
            XCTAssertEqual(files.first?.size, UploadCheckpoint.minimumSize)
            let hash = try await phone("sha256sum < \(Shell.quote(destination))")
            XCTAssertEqual(hash.split(whereSeparator: \.isWhitespace).first, expectedHash, scenario)
            print("Verified large upload \(scenario): resumed at byte offset \(half), checked SHA-256 and staging cleanup")
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<3600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw HubError.message("Upload test did not reach the expected state.")
    }

    func testUploadRecoveryOnPhone() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["DROIDHUB_UPLOAD_QA_ISOLATED_SERVER"] == "1",
              let serial = env["DROIDHUB_UPLOAD_QA_SERIAL"], let adb = env["DROIDHUB_UPLOAD_QA_ADB"],
              let remote = env["DROIDHUB_UPLOAD_QA_DIRECTORY"] else { throw XCTSkip("No explicit upload recovery fixture") }
        let client = ADBClient(executable: adb)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let identity = TransferDeviceID.hardware(try await client.hardwareSerial(for: serial) ?? serial)

        for reopen in [false, true] {
            let label = "file" + (reopen ? "-reopen" : "-reconnect")
            let testRoot = root.appendingPathComponent(label)
            let source = testRoot.appendingPathComponent("source file.bin")
            let payload = Data((0..<8192).map { UInt8($0 % 251) })
            let phoneFolder = remote + "/" + label
            try manager.createDirectory(at: testRoot, withIntermediateDirectories: true)
            try payload.write(to: source)
            let partial = testRoot.appendingPathComponent("prefix")
            try payload.prefix(2048).write(to: partial)
            _ = try await ProcessRunner.run(adb, ["-s", serial, "shell", "mkdir", phoneFolder])
            let wrapper = testRoot.appendingPathComponent("adb")
            let script = #"""
            #!/bin/sh
            cd "$(dirname "$0")" || exit 1
            shift 2
            if [ "$1" = push ] && [ ! -f started ]; then
                touch started || exit 1
                \#(Shell.quote(adb)) -s \#(Shell.quote(serial)) push prefix "$3" || exit 1
                exec sleep 30
            fi
            exec \#(Shell.quote(adb)) -s \#(Shell.quote(serial)) "$@"
            """#
            try Data(script.utf8).write(to: wrapper)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
            let store = TransferQueueStore(url: testRoot.appendingPathComponent("queue.json"))
            let model = HubModel(transferStorageURL: store.url)
            let original = model.transfers
            original.connect(TransferConnection(deviceID: identity, serial: "192.0.2.2:40001", executable: wrapper.path))
            original.enqueue([QueuedTransfer(deviceID: identity, device: "Test phone",
                                              operation: .upload(local: source, directory: phoneFolder, isDirectory: false, replaceExisting: false))])
            for _ in 0..<240 where original.items.first?.bytes != 2048 {
                try await Task.sleep(for: .milliseconds(25))
            }
            let partialBytes = original.items.first?.bytes
            if partialBytes != 2048 {
                original.disconnect(reason: "Test stopped")
                await original.waitForActive()
            }
            XCTAssertEqual(partialBytes, 2048, label)
            guard partialBytes == 2048 else { continue }

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
            let interrupted = try XCTUnwrap(store.load().first)
            XCTAssertEqual(interrupted.state, .interrupted, label)
            let pending = try await client.files(serial: serial, path: phoneFolder)
            if reopen {
                XCTAssertNil(interrupted.uploadStagingID, label)
                XCTAssertTrue(pending.isEmpty, label)
            } else {
                let previous = try XCTUnwrap(interrupted.uploadStagingID)
                XCTAssertEqual(pending.map(\.name), [".droidhub-upload-\(previous.uuidString).part"], label)
            }

            let otherStaging = ".droidhub-upload-\(UUID().uuidString).part"
            _ = try await ProcessRunner.run(adb, ["-s", serial, "push", partial.path, phoneFolder + "/" + otherStaging])
            let queue = reopen ? HubModel(transferStorageURL: store.url).transfers : original
            XCTAssertEqual(queue.items.first?.state, .interrupted, label)
            queue.connect(TransferConnection(deviceID: identity, serial: "192.0.2.2:40002", executable: wrapper.path))
            XCTAssertEqual(queue.retryableUnfinishedCount, 1, label)
            queue.retryUnfinished()
            for _ in 0..<400 where queue.items.first?.state.isInQueue == true {
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertEqual(queue.items.first?.state, .completed, "\(label): \(queue.items.first?.detail ?? "")")
            await queue.flushPersistence()
            XCTAssertEqual(try store.load().first?.state, .completed, label)
            XCTAssertNil(try store.load().first?.uploadStagingID, label)
            let files = try await client.files(serial: serial, path: phoneFolder)
            XCTAssertEqual(Set(files.map(\.name)), [source.lastPathComponent, otherStaging], label)
            let destination = phoneFolder + "/" + source.lastPathComponent
            let downloaded = testRoot.appendingPathComponent("verified")
            try await client.download(serial: serial, remote: destination, local: downloaded)
            XCTAssertEqual(try Data(contentsOf: downloaded), payload, label)
            print("Verified \(label): interrupted at 2048/8192, retried, checked bytes and staging cleanup")
        }
    }
}
