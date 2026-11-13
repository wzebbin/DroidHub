import XCTest
import DroidHubCore
@testable import DroidHub

@MainActor
final class TransferQueueTests: XCTestCase {
    private let phone = TransferDeviceID.hardware("original")
    private let otherPhone = TransferDeviceID.hardware("other")

    private func makeFolder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeADB(in directory: URL, script: String) throws -> String {
        let executable = directory.appendingPathComponent("test-adb")
        try Data(("#!/bin/sh\n" + script).utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable.path
    }

    private func download(named name: String, to directory: URL, state: QueuedTransfer.State,
                          device: TransferDeviceID? = nil) throws -> QueuedTransfer {
        let file = try XCTUnwrap(try DeviceFile.parse(Data("\(name)\u{0}f\u{0}6\u{0}".utf8), directory: "/sdcard/Download").first)
        return QueuedTransfer(deviceID: device ?? phone, device: "Test phone",
                              operation: .download(file: file, destination: directory.appendingPathComponent(name), replaceExisting: true),
                              state: state, total: 6)
    }

    private func waitUntilIdle(_ queue: TransferQueue) async throws {
        for _ in 0..<200 {
            if !queue.items.contains(where: { $0.state.isInQueue }) {
                await queue.flushPersistence()
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Queue did not settle")
    }

    func testRestoresHistoryAndOnlyRetriesUnfinishedItemsForMatchingPhone() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TransferQueueStore(url: directory.appendingPathComponent("queue.json"))
        let stored = try [
            download(named: "existing.txt", to: directory, state: .committing),
            download(named: "waiting.txt", to: directory, state: .waiting),
            download(named: "failed.txt", to: directory, state: .failed),
            download(named: "cancelled.txt", to: directory, state: .cancelled),
            download(named: "completed.txt", to: directory, state: .completed),
            download(named: "other.txt", to: directory, state: .failed, device: otherPhone)
        ]
        try store.save(stored)
        let destination = directory.appendingPathComponent("existing.txt")
        try Data("earlier result".utf8).write(to: destination)
        let executable = try makeADB(in: directory, script: #"""
        [ "$1" = "-s" ] && [ "$2" = "192.168.1.9:41002" ] && [ "$3" = "pull" ] || exit 1
        printf 'result' > "$5"
        """#)
        let queue = TransferQueue(storageURL: store.url)
        XCTAssertTrue(queue.showsRestoredItems)
        XCTAssertEqual(queue.items.map(\.id), stored.map(\.id))
        XCTAssertEqual(queue.items.map(\.state), [.interrupted, .interrupted, .failed, .cancelled, .completed, .failed])
        XCTAssertEqual(queue.retryableUnfinishedCount, 0)
        queue.connect(TransferConnection(deviceID: .hardware("different"), serial: "192.168.1.9:41002", executable: executable))
        queue.retryUnfinished()
        XCTAssertEqual(queue.retryableUnfinishedCount, 0)
        XCTAssertEqual(queue.items.first?.state, .interrupted)

        queue.connect(TransferConnection(deviceID: phone, serial: "192.168.1.9:41002", executable: executable))
        XCTAssertEqual(queue.retryableUnfinishedCount, 3)
        XCTAssertEqual(queue.items.first?.state, .interrupted)
        queue.retryUnfinished()
        try await waitUntilIdle(queue)

        XCTAssertEqual(queue.items.map(\.state), [.completed, .completed, .completed, .cancelled, .completed, .failed])
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "earlier result")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("existing (2).txt"), encoding: .utf8), "result")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("other.txt").path))
        XCTAssertEqual(try store.load().map(\.state), queue.items.map(\.state))
    }

    func testDisconnectPersistsInterruptedActiveAndWaitingTasks() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TransferQueueStore(url: directory.appendingPathComponent("queue.json"))
        let executable = try makeADB(in: directory, script: #"""
        printf 'part' > "$5"
        exec sleep 30
        """#)
        let queue = TransferQueue(storageURL: store.url)
        queue.connect(TransferConnection(deviceID: phone, serial: "test", executable: executable))
        queue.enqueue(try [
            download(named: "active.txt", to: directory, state: .waiting),
            download(named: "waiting.txt", to: directory, state: .waiting)
        ])
        for _ in 0..<200 where queue.items.first?.bytes != 4 {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(queue.items.first?.bytes, 4)
        queue.disconnect(reason: "手机已断开")
        await queue.waitForActive()

        let restored = TransferQueue(storageURL: store.url)
        XCTAssertEqual(restored.items.map(\.state), [.interrupted, .interrupted])
        XCTAssertEqual(restored.items.compactMap(\.detail), ["手机已断开", "手机已断开"])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".part") })
    }

    func testFlushingPausedAndInterruptedSnapshotsKeepsLatestState() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TransferQueueStore(url: directory.appendingPathComponent("queue.json"))
        let executable = try makeADB(in: directory, script: #"printf 'result' > "$5""#)
        let connection = TransferConnection(deviceID: phone, serial: "test", executable: executable)
        let queue = TransferQueue(storageURL: store.url)
        queue.connect(connection)
        let paused = try download(named: "paused.txt", to: directory, state: .waiting)
        let interrupted = try download(named: "interrupted.txt", to: directory, state: .waiting)

        queue.enqueue([paused, interrupted])
        queue.pause(paused.id)
        queue.disconnect(reason: "手机已断开", connectionLost: true)
        await queue.waitForActive()

        let restored = TransferQueue(storageURL: store.url)
        XCTAssertEqual(restored.items.map(\.state), [.paused, .interrupted])
        XCTAssertEqual(restored.items.map(\.resumeAfterReconnect), [nil, true])
        restored.connect(connection)
        restored.continueTransfer(paused.id)
        try await waitUntilIdle(restored)
        XCTAssertEqual(try store.load().first?.state, .completed)
    }

    func testReconnectOnlyAutomaticallyResumesConnectionLossOnTheSamePhone() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "DroidHub-Queue-Tests-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = TransferQueueStore(url: directory.appendingPathComponent("queue.json"))
        var lost = try download(named: "lost", to: directory, state: .interrupted)
        lost.resumeAfterReconnect = true
        let paused = try download(named: "paused", to: directory, state: .pausing)
        let failed = try download(named: "failed", to: directory, state: .failed)
        let quit = try download(named: "quit", to: directory, state: .transferring)
        try store.save([lost, paused, failed, quit])
        let executable = try makeADB(in: directory, script: #"printf 'result' > "$5""#)
        let original = TransferConnection(deviceID: phone, serial: "original", executable: executable)
        let other = TransferConnection(deviceID: otherPhone, serial: "other", executable: executable)
        let queue = TransferQueue(storageURL: store.url, preferences: preferences)
        queue.connect(original)
        XCTAssertEqual(queue.items.map(\.state), [.interrupted, .paused, .failed, .interrupted])

        preferences.set(true, forKey: TransferQueue.autoResumeKey)
        queue.disconnect(reason: "设备已断开", connectionLost: true)
        queue.connect(other)
        XCTAssertEqual(queue.items.map(\.state), [.interrupted, .paused, .failed, .interrupted])
        XCTAssertFalse(queue.canContinue(queue.items[1]))
        queue.connect(original)
        try await waitUntilIdle(queue)
        XCTAssertEqual(queue.items.map(\.state), [.completed, .paused, .failed, .interrupted])

        queue.continueTransfer(paused.id)
        try await waitUntilIdle(queue)
        XCTAssertEqual(try store.load().map(\.state), [.completed, .completed, .failed, .interrupted])
    }

    func testCorruptQueueIsPreservedAndMissingSourceHasClearReason() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("queue.json")
        let original = Data("corrupt snapshot".utf8)
        try original.write(to: url)
        let queue = TransferQueue(storageURL: url)
        XCTAssertNotNil(queue.storageIssue)
        queue.connect(TransferConnection(deviceID: phone, serial: "test", executable: "/usr/bin/false"))
        let file = directory.appendingPathComponent("missing.txt")
        queue.enqueue([QueuedTransfer(deviceID: phone, device: "Test phone",
                                      operation: .upload(local: file, directory: "/sdcard", isDirectory: false, replaceExisting: false))])
        try await waitUntilIdle(queue)
        XCTAssertEqual(queue.items.first?.state, .failed)
        XCTAssertTrue(queue.items.first?.detail?.contains("源项目已移动或删除") == true)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testWriteFailureBeforeCommitPreservesDestinationAndAllowsRetry() async throws {
        let directory = try makeFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appendingPathComponent("queue-storage")
        let store = TransferQueueStore(url: storage.appendingPathComponent("queue.json"))
        let executable = try makeADB(in: directory, script: #"""
        cd "$(dirname "$0")" || exit 1
        [ "$3" = pull ] || exit 2
        if [ ! -e queue-original ]; then
            mv queue-storage queue-original || exit 3
            : > queue-storage
        fi
        printf 'result' > "$5"
        """#)
        let transfer = try download(named: "report.txt", to: directory, state: .waiting)
        let destination = try XCTUnwrap(transfer.downloadDestination)
        try Data("original".utf8).write(to: destination)
        let queue = TransferQueue(storageURL: store.url)
        queue.connect(TransferConnection(deviceID: phone, serial: "test", executable: executable))
        queue.enqueue([transfer])
        try await waitUntilIdle(queue)
        XCTAssertEqual(queue.items.first?.state, .failed)
        XCTAssertTrue(queue.items.first?.detail?.contains("传输队列") == true)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "original")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".part") })

        try FileManager.default.removeItem(at: storage)
        queue.retry(transfer.id)
        try await waitUntilIdle(queue)
        XCTAssertEqual(queue.items.first?.state, .completed)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "original")
        let retriedDestination = try XCTUnwrap(queue.items.first?.downloadDestination)
        XCTAssertNotEqual(retriedDestination, destination)
        XCTAssertEqual(try String(contentsOf: retriedDestination, encoding: .utf8), "result")
        XCTAssertEqual(try store.load().first?.state, .completed)
    }

    func testFailureMessagesDistinguishOfflineStorageAndConflict() {
        XCTAssertTrue(TransferFailure.message(for: HubError.message("error: device offline"), uploading: true).contains("连接中断"))
        XCTAssertTrue(TransferFailure.message(for: HubError.message("No space left on device"), uploading: true).contains("手机存储空间不足"))
        XCTAssertTrue(TransferFailure.message(for: CocoaError(.fileWriteOutOfSpace), uploading: false).contains("Mac存储空间不足"))
        XCTAssertTrue(TransferFailure.message(for: CocoaError(.fileWriteFileExists), uploading: false).contains("同名项目"))
    }
}
