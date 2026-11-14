import XCTest
import DroidHubCore
@testable import DroidHub

@MainActor
final class TrashIntegrationTests: XCTestCase {
    func testTrashAndRestoreOnUSBAndWiFi() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let adb = env["DROIDHUB_TRASH_QA_ADB"], let remote = env["DROIDHUB_TRASH_QA_ROOT"],
              let usb = env["DROIDHUB_TRASH_QA_USB"], let wifi = env["DROIDHUB_TRASH_QA_WIFI"],
              let usbNamespace = env["DROIDHUB_TRASH_QA_USB_NAMESPACE"].flatMap(UUID.init(uuidString:)),
              let wifiNamespace = env["DROIDHUB_TRASH_QA_WIFI_NAMESPACE"].flatMap(UUID.init(uuidString:)) else {
            throw XCTSkip("No explicit trash fixture")
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        for (label, serial, namespace) in [("USB", usb, usbNamespace), ("Wi-Fi", wifi, wifiNamespace)] {
            let qa = root.appendingPathComponent(label)
            let wrapper = qa.appendingPathComponent("adb")
            let storage = qa.appendingPathComponent("queue.json")
            let store = RemoteMoveBatchStore(url: qa.appendingPathComponent("move-batches.json"))
            try store.save(RemoteMoveSnapshot(namespace: namespace))
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
                *' --delete '*)
                    if [ -f delete-mode ] && [ -f delete-id ]; then
                        case "$7" in
                            *"$(cat delete-id)"*)
                                mode=$(cat delete-mode)
                                rm delete-mode delete-id
                                if [ "$mode" = after ]; then "$adb" "$@" > delete-result || exit $?; fi
                                if [ "$mode" = partial ]; then
                                    "$adb" -s "$2" shell -T sh -c "$(cat partial-command)" || exit $?
                                fi
                                touch offline
                                printf 'adb: error: closed\n' >&2
                                exit 1 ;;
                        esac
                    fi ;;
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
            var model = HubModel(transferStorageURL: storage)
            model.adbPath = wrapper.path

            func phone(_ command: String) async throws -> String {
                let data = try await ProcessRunner.run(adb, ["-s", serial, "shell", "-T", "sh", "-c", Shell.quote(command)])
                return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
            }
            func connect() async throws {
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
            func reconnect(reopen: Bool) async throws {
                await model.refreshDevices()
                try await wait { model.transfers.connection == nil }
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
                XCTAssertTrue(reconnected, "Expected a new \(label) transport")
                try manager.removeItem(at: qa.appendingPathComponent("offline"))
                if reopen {
                    await model.shutdown()
                    model = HubModel(transferStorageURL: storage)
                    model.adbPath = wrapper.path
                }
                try await connect()
                try await wait {
                    model.canManageTrashDeletion && model.trashDeletionBatch?.checkIndex == nil
                }
            }

            let directory = remote + "/" + label + "/source"
            let names = ["01 file.TXT", "02 folder", "03 last.jpg"]
            _ = try await phone("set -e; mkdir -p \(Shell.quote(directory + "/02 folder/nested/empty")); "
                + "printf alpha > \(Shell.quote(directory + "/01 file.TXT")); "
                + "printf beta > \(Shell.quote(directory + "/02 folder/nested/item.txt")); "
                + "printf gamma > \(Shell.quote(directory + "/03 last.jpg"))")
            try await connect()
            XCTAssertEqual(model.selectedDevice?.isWireless, label == "Wi-Fi")
            let target = try await open(directory)
            let selected = try names.map { name in try XCTUnwrap(model.files.first { $0.name == name }) }
            let connection = try XCTUnwrap(model.transfers.connection)
            let download = QueuedTransfer(deviceID: connection.deviceID, device: label,
                operation: .download(file: selected[0], destination: qa.appendingPathComponent("hold"), replaceExisting: false))
            model.transfers.enqueue([download])
            try await wait { model.transfers.items.first?.state == .transferring }
            model.moveToTrash([selected[0]], in: target)
            try await wait { !model.busy }
            XCTAssertTrue(model.error?.contains("传输任务") == true)
            model.transfers.pause(download.id)
            try await wait { model.transfers.items.first?.state == .paused }
            model.error = nil
            model.moveToTrash([selected[0]], in: target)
            try await wait { !model.busy }
            XCTAssertTrue(model.error?.contains("传输任务") == true)
            model.transfers.cancel(download.id)

            model.error = nil
            try Data("after".utf8).write(to: qa.appendingPathComponent("interrupt"))
            model.moveToTrash(selected, in: target)
            try await wait { !model.busy }
            guard model.moveBatch?.checking == true else {
                throw HubError.message("Expected interruption for \(label): \(model.error ?? model.status)")
            }
            XCTAssertEqual(model.trashEntries.map(\.name), [names[0]])
            try await reconnect(reopen: true)
            XCTAssertEqual(Set(model.trashEntries.map(\.name)), Set(names.prefix(2)))
            XCTAssertFalse(try XCTUnwrap(model.moveBatch).checking)
            model.retryBatchMove()
            try await wait { !model.busy }
            XCTAssertEqual(Set(model.trashEntries.map(\.name)), Set(names))
            let sourceContents = try await phone("ls -A \(Shell.quote(directory))")
            XCTAssertTrue(sourceContents.isEmpty)
            let entries = try names.map { name in try XCTUnwrap(model.trashEntries.first { $0.name == name }) }
            let conflict = directory + "/01 file.txt"
            _ = try await phone("printf keep > \(Shell.quote(conflict))")
            model.restoreTrash([entries[0]])
            try await wait { !model.busy }
            XCTAssertTrue(model.error?.contains("同名") == true)
            XCTAssertEqual(model.trashEntries.count, 3)
            let existing = try await phone("cat \(Shell.quote(conflict))")
            XCTAssertEqual(existing, "keep")
            _ = try await phone("rm -- \(Shell.quote(conflict)); rmdir -- \(Shell.quote(directory))")
            model.error = nil
            model.restoreTrash([entries[0]])
            try await wait { !model.busy }
            XCTAssertTrue(model.error?.contains("原目录不存在") == true)
            XCTAssertEqual(model.trashEntries.count, 3)
            _ = try await phone("mkdir -- \(Shell.quote(directory))")

            let reconnected = try XCTUnwrap(model.transfers.connection)
            let upload = QueuedTransfer(deviceID: reconnected.deviceID, device: label,
                operation: .upload(local: qa.appendingPathComponent(names[0]), directory: directory,
                                   isDirectory: false, replaceExisting: false), state: .paused)
            model.transfers.enqueue([upload])
            model.error = nil
            model.restoreTrash([entries[0]])
            try await wait { !model.busy }
            XCTAssertTrue(model.error?.contains("传输任务") == true)
            XCTAssertEqual(model.trashEntries.count, 3)
            model.transfers.cancel(upload.id)

            model.error = nil
            try Data("before".utf8).write(to: qa.appendingPathComponent("interrupt"))
            model.restoreTrash(entries)
            try await wait { !model.busy }
            guard model.moveBatch?.checking == true else {
                throw HubError.message("Expected interruption for \(label): \(model.error ?? model.status)")
            }
            XCTAssertEqual(Set(model.trashEntries.map(\.name)), Set(names.dropFirst()))
            try await reconnect(reopen: false)
            XCTAssertEqual(model.moveBatch?.completed, 1)
            XCTAssertFalse(try XCTUnwrap(model.moveBatch).checking)
            model.retryBatchMove()
            try await wait { !model.busy }
            XCTAssertTrue(model.trashEntries.isEmpty)
            XCTAssertTrue(try store.loadSnapshot().trash.isEmpty)
            let restored = try await phone("set -e; test -d \(Shell.quote(directory + "/02 folder/nested/empty")); "
                + "cat \(Shell.quote(directory + "/01 file.TXT")) \(Shell.quote(directory + "/02 folder/nested/item.txt")) "
                + "\(Shell.quote(directory + "/03 last.jpg"))")
            XCTAssertEqual(restored, "alphabetagamma")

            let singleTarget = try await open(directory)
            let single = try XCTUnwrap(model.files.first { $0.name == names[0] })
            model.moveToTrash([single], in: singleTarget)
            try await wait { !model.busy }
            let entry = try XCTUnwrap(model.trashEntries.first)
            model.restoreTrash([entry])
            try await wait { !model.busy }
            XCTAssertTrue(model.trashEntries.isEmpty)
            XCTAssertTrue(model.moveBatch?.isFinished == true)
            let alternate = remote + "/" + label + "/alternate"
            let sourceA = alternate + "/source A"
            let sourceB = alternate + "/source B"
            let chosen = alternate + "/chosen"
            let extra = alternate + "/other"
            let lowerDuplicate = "twin.txt"
            let upperDuplicate = "Twin.TXT"
            _ = try await phone("set -e; mkdir -p \(Shell.quote(sourceA + "/02 folder/nested/empty")) \(Shell.quote(sourceB)) "
                + "\(Shell.quote(chosen)) \(Shell.quote(extra)); "
                + "printf one > \(Shell.quote(sourceA + "/01 file.TXT")); "
                + "printf two > \(Shell.quote(sourceA + "/02 folder/nested/item.txt")); "
                + "printf three > \(Shell.quote(sourceA + "/03 last.jpg")); "
                + "printf upper > \(Shell.quote(sourceA + "/" + upperDuplicate)); "
                + "printf lower > \(Shell.quote(sourceB + "/" + lowerDuplicate))")
            let targetA = try await open(sourceA)
            let fromA = try (names + [upperDuplicate]).map { name in
                try XCTUnwrap(model.files.first { $0.name == name })
            }
            model.moveToTrash(fromA, in: targetA)
            try await wait { !model.busy }
            let targetB = try await open(sourceB)
            let fromB = try XCTUnwrap(model.files.first)
            model.moveToTrash([fromB], in: targetB)
            try await wait { !model.busy }
            _ = try await phone("rmdir -- \(Shell.quote(sourceA)) \(Shell.quote(sourceB))")
            let picker = try await open(alternate)
            let duplicates = try [upperDuplicate, lowerDuplicate].map { name in
                try XCTUnwrap(model.trashEntries.first { $0.name == name })
            }
            let selectedForRestore = try names.map { name in
                try XCTUnwrap(model.trashEntries.first { $0.name == name })
            }
            let candidateDirs = try await model.trashRestoreDirectories(at: alternate, in: picker)
            XCTAssertEqual(Set(candidateDirs.map(\.name)), ["chosen", "other"])
            let sameBatch = try await model.previewTrashRestore(duplicates, to: chosen, in: picker)
            XCTAssertTrue(sameBatch.allSatisfy { $0.preview.issues == ["批次内重名"] && $0.preview.move == nil })
            let existingTwin = chosen + "/" + lowerDuplicate
            _ = try await phone("printf untouched > \(Shell.quote(existingTwin))")
            let bothConflicts = try await model.previewTrashRestore(duplicates, to: chosen, in: picker)
            XCTAssertTrue(bothConflicts.allSatisfy {
                $0.preview.issues == ["批次内重名", "目标目录已有同名项目"] && $0.preview.move == nil
            })
            let untouched = try await phone("cat \(Shell.quote(existingTwin))")
            XCTAssertEqual(untouched, "untouched")
            let crossVolume = try await model.previewTrashRestore(selectedForRestore, to: "/data/local/tmp", in: picker)
            XCTAssertTrue(crossVolume.allSatisfy { $0.preview.issues.contains("只能在同一存储卷内恢复") })
            let clean = try await model.previewTrashRestore(selectedForRestore, to: chosen, in: picker)
            XCTAssertTrue(clean.allSatisfy { $0.preview.issues.isEmpty && $0.preview.move != nil })
            let lateConflict = chosen + "/01 FILE.txt"
            _ = try await phone("printf preserve > \(Shell.quote(lateConflict))")
            model.error = nil
            model.startTrashRestore(clean, in: picker)
            try await wait { !model.busy }
            XCTAssertTrue(model.error?.contains("目标目录已有同名") == true, model.error ?? "")
            XCTAssertEqual(model.trashEntries.count, 5)
            let kept = try await phone("cat \(Shell.quote(lateConflict))")
            XCTAssertEqual(kept, "preserve")
            _ = try await phone("rm -- \(Shell.quote(lateConflict))")

            let chosenConnection = try XCTUnwrap(model.transfers.connection)
            let queued = QueuedTransfer(deviceID: chosenConnection.deviceID, device: label,
                operation: .upload(local: qa.appendingPathComponent(names[0]), directory: chosen,
                                   isDirectory: false, replaceExisting: false), state: .paused)
            model.transfers.enqueue([queued])
            let occupied = try await model.previewTrashRestore(selectedForRestore, to: chosen, in: picker)
            XCTAssertTrue(occupied.first?.preview.issues.contains(where: { $0.contains("传输任务") }) == true)
            model.error = nil
            model.startTrashRestore(clean, in: picker)
            try await wait { !model.busy }
            XCTAssertTrue(model.error?.contains("传输任务") == true)
            XCTAssertEqual(model.trashEntries.count, 5)
            model.transfers.cancel(queued.id)

            model.error = nil
            try Data("after".utf8).write(to: qa.appendingPathComponent("interrupt"))
            model.startTrashRestore(clean, in: picker)
            try await wait { !model.busy }
            guard model.moveBatch?.checking == true else {
                throw HubError.message("Expected chosen restore interruption for \(label): \(model.error ?? model.status)")
            }
            XCTAssertEqual(model.trashEntries.count, 4)
            try await reconnect(reopen: true)
            XCTAssertEqual(model.moveBatch?.completed, 2)
            XCTAssertTrue(model.moveBatch?.destination.hasSuffix("/chosen") == true)
            XCTAssertEqual(Set(model.trashEntries.map(\.name)), Set([names[2], upperDuplicate, lowerDuplicate]))
            let retryConflict = chosen + "/03 last.jpg"
            _ = try await phone("printf retry-conflict > \(Shell.quote(retryConflict))")
            model.retryBatchMove()
            try await wait { !model.busy }
            XCTAssertTrue(model.moveBatch?.detail?.contains("目标目录已有同名") == true)
            XCTAssertEqual(model.moveBatch?.completed, 2)
            _ = try await phone("rm -- \(Shell.quote(retryConflict))")
            model.retryBatchMove()
            try await wait { !model.busy }
            XCTAssertTrue(model.moveBatch?.isFinished == true)
            XCTAssertEqual(Set(model.trashEntries.map(\.name)), Set([upperDuplicate, lowerDuplicate]))
            let chosenContent = try await phone("set -e; test ! -e \(Shell.quote(sourceA)); "
                + "test -d \(Shell.quote(chosen + "/02 folder/nested/empty")); "
                + "cat \(Shell.quote(chosen + "/01 file.TXT")) \(Shell.quote(chosen + "/02 folder/nested/item.txt")) "
                + "\(Shell.quote(chosen + "/03 last.jpg"))")
            XCTAssertEqual(chosenContent, "onetwothree")

            let singlePicker = try await open(alternate)
            let singlePreview = try await model.previewTrashRestore([duplicates[0]], to: extra, in: singlePicker)
            model.startTrashRestore(singlePreview, in: singlePicker)
            try await wait { !model.busy }
            XCTAssertEqual(model.trashEntries.map(\.name), [lowerDuplicate])
            let singleContent = try await phone("cat \(Shell.quote(extra + "/" + upperDuplicate))")
            XCTAssertEqual(singleContent, "upper")
            print("Verified \(label) chosen trash restore, duplicate and existing conflicts, protected destination, same volume and reconnect")
            let deleteSource = remote + "/" + label + "/delete-source"
            let deleteNames = ["delete file.txt", "delete folder", "delete alone.txt", "keep.txt"]
            _ = try await phone("set -e; mkdir -p \(Shell.quote(deleteSource + "/delete folder/empty")); "
                + "printf selected > \(Shell.quote(deleteSource + "/delete file.txt")); "
                + "printf selected > \(Shell.quote(deleteSource + "/delete folder/remove-me.txt")); "
                + "printf remaining > \(Shell.quote(deleteSource + "/delete folder/keep-until-retry.txt")); "
                + "printf single > \(Shell.quote(deleteSource + "/delete alone.txt")); "
                + "printf untouched > \(Shell.quote(deleteSource + "/keep.txt"))")
            let deleteTarget = try await open(deleteSource)
            let deleteFiles = try deleteNames.map { name in try XCTUnwrap(model.files.first { $0.name == name }) }
            model.moveToTrash(deleteFiles, in: deleteTarget)
            try await wait { !model.busy }
            let trashFiles = try deleteNames.map { name in try XCTUnwrap(model.trashEntries.first { $0.name == name }) }
            let deletionConnection = try XCTUnwrap(model.transfers.connection)
            let protectedUpload = QueuedTransfer(deviceID: deletionConnection.deviceID, device: label,
                operation: .upload(local: qa.appendingPathComponent(deleteNames[0]), directory: deleteSource,
                                   isDirectory: false, replaceExisting: false), state: .paused)
            model.transfers.enqueue([protectedUpload])
            model.error = nil
            model.permanentlyDeleteTrash(Array(trashFiles.prefix(2)))
            try await wait { !model.busy }
            XCTAssertTrue(model.error?.contains("传输任务") == true)
            XCTAssertNil(model.trashDeletionBatch)
            model.transfers.cancel(protectedUpload.id)
            model.error = nil

            func interruptDeletion(_ entry: TrashEntry, mode: String) throws {
                try Data(entry.id.uuidString.utf8).write(to: qa.appendingPathComponent("delete-id"))
                try Data(mode.utf8).write(to: qa.appendingPathComponent("delete-mode"))
            }

            let partialCommand = Shell.quote("rm -- \(Shell.quote(trashFiles[1].stored + "/remove-me.txt"))")
            try Data(partialCommand.utf8).write(to: qa.appendingPathComponent("partial-command"))
            try interruptDeletion(trashFiles[1], mode: "partial")
            model.permanentlyDeleteTrash(Array(trashFiles.prefix(2)))
            try await wait { !model.busy }
            guard model.trashDeletionBatch?.checkIndex == 1 else {
                throw HubError.message("Expected partial deletion interruption for \(label): \(model.error ?? model.status)")
            }
            XCTAssertEqual(model.trashDeletionBatch?.completed, 1)
            try await reconnect(reopen: true)
            XCTAssertEqual(model.trashDeletionBatch?.items.map(\.state), [.deleted, .partial])
            XCTAssertEqual(model.trashEntries.first(where: { $0.id == trashFiles[1].id })?.partiallyDeleted, true)
            let remainingChild = try await phone("cat \(Shell.quote(trashFiles[1].stored + "/keep-until-retry.txt"))")
            XCTAssertEqual(remainingChild, "remaining")
            try interruptDeletion(trashFiles[1], mode: "after")
            model.retryTrashDeletion()
            try await wait { !model.busy }
            XCTAssertEqual(model.trashDeletionBatch?.checkIndex, 1)
            try await reconnect(reopen: false)
            XCTAssertTrue(model.trashDeletionBatch?.isFinished == true)
            XCTAssertFalse(model.trashEntries.contains(where: { $0.id == trashFiles[1].id }))

            try interruptDeletion(trashFiles[2], mode: "before")
            model.permanentlyDeleteTrash([trashFiles[2]])
            try await wait { !model.busy }
            XCTAssertEqual(model.trashDeletionBatch?.checkIndex, 0)
            try await reconnect(reopen: true)
            XCTAssertEqual(model.trashDeletionBatch?.items.map(\.state), [.present])
            model.retryTrashDeletion()
            try await wait { !model.busy }
            XCTAssertTrue(model.trashDeletionBatch?.isFinished == true)
            model.restoreTrash([trashFiles[3]])
            try await wait { !model.busy }
            let restoredUnselected = try await phone("set -e; test ! -e \(Shell.quote(trashFiles[0].stored)); "
                + "test ! -e \(Shell.quote(trashFiles[1].stored)); test ! -e \(Shell.quote(trashFiles[2].stored)); "
                + "cat \(Shell.quote(deleteSource + "/keep.txt"))")
            XCTAssertEqual(restoredUnselected, "untouched")
            let retained = try XCTUnwrap(model.trashEntries.first { $0.name == lowerDuplicate })
            let client = ADBClient(executable: adb)
            let planned = try await client.prepareTrashDeletion(serial: serial, path: retained.stored,
                namespace: namespace, entryID: retained.id, isDirectory: false)
            let saved = retained.stored + ".qa-original"
            _ = try await phone("mv -- \(Shell.quote(retained.stored)) \(Shell.quote(saved)); "
                + "printf replacement > \(Shell.quote(retained.stored))")
            let unknown = try await client.reconcileTrashDeletion(serial: serial, item: planned)
            XCTAssertEqual(unknown, .unknown)
            let guarded = try await client.applyTrashDeletion(serial: serial, item: planned)
            XCTAssertEqual(guarded, .unknown)
            let intact = try await phone("cat \(Shell.quote(retained.stored)); "
                + "rm -- \(Shell.quote(retained.stored)); mv -- \(Shell.quote(saved)) \(Shell.quote(retained.stored))")
            XCTAssertEqual(intact, "replacement")
            print("Verified \(label) permanent deletion, transfer protection, partial and completed disconnect recovery, and unselected restore")
            let clearSource = remote + "/" + label + "/clear-source"
            _ = try await phone("set -e; mkdir -p \(Shell.quote(clearSource + "/clear folder/empty")); "
                + "printf selected > \(Shell.quote(clearSource + "/clear file.txt")); "
                + "printf partial > \(Shell.quote(clearSource + "/clear folder/remove-me.txt")); "
                + "printf remaining > \(Shell.quote(clearSource + "/clear folder/remaining.txt")); "
                + "printf added-later > \(Shell.quote(clearSource + "/new after confirmation.txt"))")
            let clearTarget = try await open(clearSource)
            let firstItems = model.files.filter { $0.name.hasPrefix("clear ") }
            model.moveToTrash(firstItems, in: clearTarget)
            try await wait { !model.busy }
            let clearConnection = try XCTUnwrap(model.transfers.connection)
            let confirmation = try XCTUnwrap(model.prepareTrashClear(for: clearConnection.deviceID))
            XCTAssertEqual(confirmation.phoneName, model.selectedDevice?.model)
            XCTAssertEqual(Set(confirmation.entries.map(\.name)), ["clear file.txt", "clear folder", lowerDuplicate])
            XCTAssertNil(model.prepareTrashClear(for: .usb("unrelated-phone")))
            let added = try XCTUnwrap(model.files.first { $0.name == "new after confirmation.txt" })
            model.moveToTrash([added], in: clearTarget)
            try await wait { !model.busy }
            let lateEntry = try XCTUnwrap(model.trashEntries.first { $0.name == added.name })
            XCTAssertFalse(confirmation.entries.contains { $0.id == lateEntry.id })

            let protectedFolder = QueuedTransfer(deviceID: clearConnection.deviceID, device: label,
                operation: .upload(local: qa.appendingPathComponent("clear folder"), directory: clearSource,
                                   isDirectory: true, replaceExisting: false), state: .paused)
            model.transfers.enqueue([protectedFolder])
            model.error = nil
            model.clearTrash(confirmation)
            try await wait { !model.busy }
            XCTAssertTrue(model.error?.contains("clear folder") == true && model.error?.contains("传输任务") == true)
            XCTAssertEqual(Set(model.trashEntries.map(\.id)), Set(confirmation.entries.map(\.id) + [lateEntry.id]))
            for entry in confirmation.entries { _ = try await phone("test -e \(Shell.quote(entry.stored))") }
            model.transfers.cancel(protectedFolder.id)

            let folder = try XCTUnwrap(confirmation.entries.first { $0.name == "clear folder" })
            let partialClear = Shell.quote("rm -- \(Shell.quote(folder.stored + "/remove-me.txt"))")
            try Data(partialClear.utf8).write(to: qa.appendingPathComponent("partial-command"))
            try interruptDeletion(folder, mode: "partial")
            model.error = nil
            model.clearTrash(confirmation)
            try await wait { !model.busy }
            let interrupted = try XCTUnwrap(model.trashDeletionBatch)
            XCTAssertEqual(interrupted.isClear, true)
            XCTAssertEqual(interrupted.checkIndex.map { interrupted.items[$0].id }, folder.id)
            try await reconnect(reopen: true)
            let resumed = try XCTUnwrap(model.trashDeletionBatch)
            XCTAssertEqual(resumed.items.first { $0.id == folder.id }?.state, .partial)
            XCTAssertEqual(model.trashEntries.first { $0.id == folder.id }?.partiallyDeleted, true)
            XCTAssertNil(resumed.checkIndex)
            model.retryTrashDeletion()
            try await wait { !model.busy }
            let cleared = try XCTUnwrap(model.trashDeletionBatch)
            XCTAssertTrue(cleared.isFinished)
            XCTAssertEqual(Set(cleared.items.map(\.id)), Set(confirmation.entries.map(\.id)))
            XCTAssertEqual(model.trashEntries.map(\.id), [lateEntry.id])
            for entry in confirmation.entries { _ = try await phone("test ! -e \(Shell.quote(entry.stored))") }
            model.restoreTrash([lateEntry])
            try await wait { !model.busy }
            let lateContents = try await phone("cat \(Shell.quote(added.path))")
            XCTAssertEqual(lateContents, "added-later")
            XCTAssertNil(model.prepareTrashClear(for: clearConnection.deviceID))
            print("Verified \(label) clear confirmation scope, transfer block, partial reconnect and retry, and restoration of the late item")
            await model.shutdown()
            print("Verified \(label) trash and restore, actual reconnects, conflict protection and file contents")
        }
    }

    func testLoadsAndUpgradesExistingMoveJournal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("move-batches.json")
        let previous = RemoteMoveBatch(device: .usb("fixture"), destination: "/target", moves: [])
        try JSONEncoder().encode([previous]).write(to: url)
        let store = RemoteMoveBatchStore(url: url)
        let snapshot = try store.loadSnapshot()
        XCTAssertEqual(snapshot.batches.first?.destination, previous.destination)
        XCTAssertTrue(snapshot.trash.isEmpty)
        try store.save(snapshot)
        XCTAssertEqual(try store.loadSnapshot().namespace, snapshot.namespace)
    }

    private func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<800 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw HubError.message("Trash fixture timed out at line \(line).")
    }
}
