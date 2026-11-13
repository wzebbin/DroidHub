import XCTest
import DroidHubCore
@testable import DroidHub

@MainActor
final class FolderRecoveryIntegrationTests: XCTestCase {
    func testFolderUploadAndDownloadResumeOnPhone() async throws {
        let env = ProcessInfo.processInfo.environment
        let usbGate = env["DROIDHUB_FOLDER_QA_USB_GATE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let onlyScenario = env["DROIDHUB_FOLDER_QA_SCENARIO"]
        guard env["DROIDHUB_FOLDER_QA_ISOLATED_SERVER"] == "1" || usbGate != nil,
              let serial = env["DROIDHUB_FOLDER_QA_SERIAL"], let adb = env["DROIDHUB_FOLDER_QA_ADB"],
              let remote = env["DROIDHUB_FOLDER_QA_DIRECTORY"] else { throw XCTSkip("No explicit folder recovery fixture") }
        let client = ADBClient(executable: adb)
        if usbGate != nil {
            let devices = try await client.devices()
            guard devices.contains(where: { $0.serial == serial && !$0.isWireless && $0.isOnline }) else {
                throw HubError.message("The requested USB test device is not online.")
            }
        }
        let suite = "DroidHub-Folder-QA-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.set(true, forKey: TransferQueue.autoResumeKey)
        defer { preferences.removePersistentDomain(forName: suite) }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "folder 'test'"
        let source = root.appendingPathComponent(name)
        let large = "nested/large 'payload'.bin"
        let smallFiles = ["a-note.txt": "retained", "b-repair.txt": "verified"]
        let cutoff: Int64 = 8 * 1024 * 1024
        let emptyFolders = ["nested/empty", "空目录"]
        for path in emptyFolders {
            try manager.createDirectory(at: source.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        defer { try? manager.removeItem(at: root) }
        for (path, data) in smallFiles {
            try Data(data.utf8).write(to: source.appendingPathComponent(path))
        }
        _ = try await ProcessRunner.run("/bin/dd", ["if=/dev/urandom", "of=\(source.appendingPathComponent(large).path)", "bs=1048576", "count=64"])
        let digest = try await ProcessRunner.run("/usr/bin/shasum", ["-a", "256", source.appendingPathComponent(large).path])
        let reference = try XCTUnwrap(String(decoding: digest, as: UTF8.self).split(whereSeparator: \.isWhitespace).first)

        func phone(_ command: String) async throws -> String {
            let data = try await ProcessRunner.run(adb, ["-s", serial, "shell", "-T", "sh", "-c", Shell.quote(command)], timeout: 60)
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        }

        let phoneSource = remote + "/" + name
        _ = try await phone("mkdir -p -- " + emptyFolders.map { Shell.quote(phoneSource + "/" + $0) }.joined(separator: " "))
        for path in Array(smallFiles.keys) + [large] {
            _ = try await ProcessRunner.run(adb, ["-s", serial, "push", source.appendingPathComponent(path).path,
                                                  phoneSource + "/" + path], timeout: 120)
        }
        let remoteFiles = try await client.files(serial: serial, path: remote)
        let folder = try XCTUnwrap(remoteFiles.first { $0.name == name && $0.isDirectory })
        var matched = false
        for reopen in (usbGate == nil ? [false, true] : [true, false]) {
            for upload in [true, false] {
                let label = (upload ? "upload" : "download") + (reopen ? "-pause-reopen" : "-auto-reconnect")
                guard onlyScenario == nil || onlyScenario == label else { continue }
                matched = true
                let fixture = root.appendingPathComponent(label)
                try manager.createDirectory(at: fixture, withIntermediateDirectories: true)
                let log = fixture.appendingPathComponent("requests")
                let wrapper = fixture.appendingPathComponent("adb")
                try makeWrapper(wrapper, adb: adb, log: log, downloadPath: phoneSource + "/" + large,
                                cutoff: cutoff, usbSerial: usbGate == nil ? nil : serial)
                let phoneParent = remote + "/" + label
                if upload { _ = try await phone("mkdir -- \(Shell.quote(phoneParent))") }
                let destination = fixture.appendingPathComponent(name)
                let operation: QueuedTransfer.Operation = upload
                    ? .upload(local: source, directory: phoneParent, isDirectory: true, replaceExisting: false)
                    : .download(file: folder, destination: destination, replaceExisting: false)
                let store = TransferQueueStore(url: fixture.appendingPathComponent("queue.json"))
                let model = HubModel(transferStorageURL: store.url, transferPreferences: preferences)
                model.adbPath = wrapper.path
                await model.refreshDevices()
                let original = model.transfers
                try await waitUntil { original.connection?.serial == serial }
                let connection = try XCTUnwrap(original.connection)
                let initialTransport = model.selectedDevice?.transportID
                let task = QueuedTransfer(deviceID: connection.deviceID, device: "Test phone", operation: operation)
                original.enqueue([task])
                let partial = cutoff + Int64(smallFiles.values.reduce(0) { $0 + $1.utf8.count })
                do {
                    try await waitUntil { original.items.first?.bytes == partial || original.items.first?.state == .failed }
                } catch {
                    await model.shutdown()
                    throw error
                }
                guard original.items.first?.bytes == partial else {
                    let reason = original.items.first?.detail
                    await model.shutdown()
                    return XCTFail("\(label): \(reason ?? "Expected saved progress")")
                }
                XCTAssertEqual(original.items.first?.folderProgress?.completedFiles, 2)
                XCTAssertEqual(original.items.first?.folderProgress?.totalFiles, 3)
                XCTAssertEqual(original.items.first?.folderProgress?.currentFile, large)
                if reopen {
                    original.pause(task.id)
                    await original.waitForActive()
                    XCTAssertEqual(original.items.first?.state, .paused)
                    await model.shutdown()
                } else {
                    if let usbGate {
                        try Data().write(to: usbGate.appendingPathComponent(label + "-ready"))
                        do {
                            _ = try await waitForUSB(client: client, serial: serial, online: false)
                        } catch {
                            await model.shutdown()
                            throw error
                        }
                        try Data().write(to: usbGate.appendingPathComponent(label + "-unplugged"))
                    } else {
                        _ = try await ProcessRunner.run(adb, ["disconnect", serial])
                    }
                    await model.refreshDevices()
                    await original.waitForActive()
                    let offline = try await client.devices()
                    XCTAssertFalse(offline.contains { $0.serial == serial && $0.isOnline })
                }
                let saved = try XCTUnwrap(store.load().first)
                XCTAssertEqual(saved.state, reopen ? .paused : .interrupted, "\(label): \(saved.detail ?? "")")
                XCTAssertEqual(saved.bytes, partial, label)
                if !reopen {
                    XCTAssertEqual(saved.resumeAfterReconnect, true)
                    if usbGate != nil {
                        let plugged = try await waitForUSB(client: client, serial: serial, online: true)
                        XCTAssertNotNil(initialTransport)
                        XCTAssertNotNil(plugged?.transportID)
                        XCTAssertNotEqual(initialTransport, plugged?.transportID)
                    } else {
                        _ = try await ProcessRunner.run(adb, ["connect", serial])
                    }
                }
                let stage = ".droidhub-folder-\(task.id.uuidString).part"
                let phoneResult = phoneParent + "/" + name
                if upload {
                    _ = try await phone("test ! -e \(Shell.quote(phoneResult))")
                    if reopen {
                        _ = try await phone("printf tampered > \(Shell.quote(phoneParent + "/" + stage + "/tree/b-repair.txt"))")
                    }
                } else {
                    XCTAssertFalse(manager.fileExists(atPath: destination.path))
                    if reopen { try Data("tampered".utf8).write(to: fixture.appendingPathComponent(stage + "/tree/b-repair.txt")) }
                }

                let resumedModel: HubModel
                if reopen {
                    resumedModel = HubModel(transferStorageURL: store.url, transferPreferences: preferences)
                    resumedModel.adbPath = wrapper.path
                } else {
                    resumedModel = model
                }
                await resumedModel.refreshDevices()
                let queue = resumedModel.transfers
                try await waitUntil { queue.connection?.serial == serial }
                XCTAssertEqual(queue.connection?.deviceID, connection.deviceID)
                if reopen {
                    XCTAssertEqual(queue.items.first?.state, .paused, label)
                    XCTAssertEqual(queue.items.first?.folderProgress?.completedFiles, 2)
                    XCTAssertEqual(queue.retryableUnfinishedCount, 0)
                    queue.retryUnfinished()
                    XCTAssertEqual(queue.items.first?.state, .paused, label)
                    queue.continueTransfer(task.id)
                }
                do {
                    try await waitUntil { queue.items.first?.state.isInQueue == false }
                } catch {
                    queue.disconnect(reason: "Test timed out")
                    await queue.waitForActive()
                    throw error
                }
                XCTAssertEqual(queue.items.first?.state, .completed, "\(label): \(queue.items.first?.detail ?? "")")
                XCTAssertEqual(queue.items.first?.folderProgress?.completedFiles, 3)
                XCTAssertEqual(queue.items.first?.folderProgress?.totalFiles, 3)
                XCTAssertNil(queue.items.first?.folderProgress?.currentFile)
                await queue.flushPersistence()
                XCTAssertEqual(try store.load().first?.state, .completed)
                let requests = try String(contentsOf: log, encoding: .utf8).split(whereSeparator: \.isNewline)
                XCTAssertEqual(requests.filter { $0 == "a-note.txt" }.count, 1, label)
                XCTAssertEqual(requests.filter { $0 == "b-repair.txt" }.count, reopen ? 2 : 1, label)
                XCTAssertEqual(requests.filter { $0.hasPrefix("offset ") }, ["offset 0", "offset \(cutoff)"], label)
                if upload {
                    let parent = try await client.files(serial: serial, path: phoneParent)
                    XCTAssertEqual(parent.map(\.name), [name])
                    let children = try await client.files(serial: serial, path: phoneResult)
                    XCTAssertEqual(Set(children.map(\.name)), Set(Array(smallFiles.keys) + ["nested", "空目录"]))
                    let nested = try await client.files(serial: serial, path: phoneResult + "/nested")
                    XCTAssertEqual(Set(nested.map(\.name)), ["large 'payload'.bin", "empty"])
                    for path in emptyFolders {
                        let contents = try await client.files(serial: serial, path: phoneResult + "/" + path)
                        XCTAssertTrue(contents.isEmpty)
                    }
                    for (path, expected) in smallFiles {
                        let actual = try await phone("cat -- \(Shell.quote(phoneResult + "/" + path))")
                        XCTAssertEqual(actual, expected)
                    }
                    let hash = try await phone("sha256sum < \(Shell.quote(phoneResult + "/" + large))")
                    XCTAssertEqual(hash.split(whereSeparator: \.isWhitespace).first, reference)
                } else {
                    XCTAssertFalse(manager.fileExists(atPath: fixture.appendingPathComponent(stage).path))
                    XCTAssertEqual(Set(try manager.contentsOfDirectory(atPath: destination.path)), Set(Array(smallFiles.keys) + ["nested", "空目录"]))
                    XCTAssertEqual(Set(try manager.contentsOfDirectory(atPath: destination.appendingPathComponent("nested").path)), ["large 'payload'.bin", "empty"])
                    for path in emptyFolders {
                        XCTAssertTrue(try manager.contentsOfDirectory(atPath: destination.appendingPathComponent(path).path).isEmpty)
                    }
                    for (path, expected) in smallFiles {
                        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent(path), encoding: .utf8), expected)
                    }
                    XCTAssertTrue(manager.contentsEqual(atPath: destination.appendingPathComponent(large).path,
                                                        andPath: source.appendingPathComponent(large).path))
                }
                print("Verified folder \(label): skipped verified files, resumed at \(cutoff), matched contents and empty directories")
                if let usbGate {
                    try Data().write(to: usbGate.appendingPathComponent(label + "-verified"))
                }
            }
        }
        XCTAssertTrue(matched, "No folder recovery scenario matched the fixture configuration")
    }

    private func makeWrapper(_ url: URL, adb: String, log: URL, downloadPath: String, cutoff: Int64,
                             usbSerial: String?) throws {
        let script = #"""
        #!/usr/bin/python3
        import os, re, shlex, subprocess, sys, time
        adb = \#(String(reflecting: adb))
        log = \#(String(reflecting: log.path))
        cutoff = \#(cutoff)
        args = sys.argv[1:]
        usb_serial = \#(usbSerial.map { String(reflecting: $0) } ?? "None")
        if usb_serial is not None and args == ["devices", "-l"]:
            listing = subprocess.run([adb, *args], capture_output=True, text=True)
            sys.stderr.write(listing.stderr)
            for line in listing.stdout.splitlines():
                if line.startswith("List of") or (line.split() and line.split()[0] == usb_serial):
                    print(line)
            sys.exit(listing.returncode)
        def note(line):
            with open(log, "a") as output:
                output.write(line + "\n")
        if len(args) >= 4 and args[2] in ("push", "pull"):
            note(os.path.basename(args[3]))
        if len(args) == 7 and args[2] == "shell":
            script = args[6]
            match = re.match(r"'tail -c \+(\d+) ", script)
            if match:
                offset = int(match[1]) - 1
                note(f"offset {offset}")
                if offset == 0:
                    path = \#(String(reflecting: downloadPath))
                    hold = 240 if usb_serial is not None else 45
                    args[6] = shlex.quote(f"head -c {cutoff} -- {shlex.quote(path)} && sleep {hold}")
            elif 'cat 3<&9 >> "$payload"' in script:
                offset = os.lseek(0, 0, os.SEEK_CUR)
                note(f"offset {offset}")
                if offset == 0:
                    reader, writer = os.pipe()
                    parent = os.getpid()
                    if os.fork() == 0:
                        os.close(reader)
                        try:
                            remaining = cutoff
                            while remaining:
                                data = os.read(0, min(remaining, 65536))
                                if not data:
                                    break
                                remaining -= len(data)
                                while data:
                                    data = data[os.write(writer, data):]
                            for _ in range(2400 if usb_serial is not None else 600):
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
        os.execv(adb, [adb, *args])
        """#
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func waitForUSB(client: ADBClient, serial: String, online: Bool) async throws -> AndroidDevice? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(180))
        while clock.now < deadline {
            let devices = try await client.devices(timeout: 3)
            let device = devices.first { $0.serial == serial && !$0.isWireless && $0.isOnline }
            if (device != nil) == online { return device }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw HubError.message(online ? "USB cable was not reconnected in time." : "USB cable was not unplugged in time.")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<9600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw HubError.message("Folder transfer did not reach the expected state.")
    }
}
