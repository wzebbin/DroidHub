import Foundation
import Combine
import CryptoKit
import SwiftUI
import DroidHubCore

enum TransferDeviceID: Codable, Hashable, Sendable {
    case hardware(String)
    case usb(String)
    case session(UUID)

    static func hardwareFingerprint(_ serial: String) -> String {
        SHA256.hash(data: Data(serial.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct TransferConnection: Equatable {
    let deviceID: TransferDeviceID
    let serial: String
    let executable: String

    var client: ADBClient { ADBClient(executable: executable) }
}

struct QueuedTransfer: Identifiable, Codable, Sendable {
    enum State: String, Codable, Sendable {
        case waiting, transferring, verifying, committing, pausing, paused, cancelling, completed, cancelled, failed, skipped, interrupted

        var isReading: Bool { self == .transferring || self == .verifying }
        var canPause: Bool { self == .waiting || isReading }
        var canCancel: Bool { canPause || self == .paused }
        var canRetry: Bool { self == .cancelled || canRetryInBulk }
        var canRetryInBulk: Bool { self == .interrupted || self == .failed }
        var isInQueue: Bool { canPause || self == .committing || self == .cancelling || self == .pausing }
        var canClear: Bool { !isInQueue && self != .interrupted && self != .paused }
    }

    enum Operation: Codable, Sendable {
        case upload(local: URL, directory: String, isDirectory: Bool, replaceExisting: Bool)
        case download(file: DeviceFile, destination: URL, replaceExisting: Bool)
    }

    var id = UUID()
    let deviceID: TransferDeviceID
    let device: String
    var operation: Operation
    var state: State = .waiting
    var bytes: Int64 = 0
    var total: Int64?
    var detail: String?
    var uploadStagingID: UUID?
    var uploadResumeID: UUID?
    var resumeAfterReconnect: Bool?
    var folderProgress: FolderTransferProgress?

    var name: String {
        switch operation {
        case .upload(let local, _, _, _): return local.lastPathComponent
        case .download(_, let destination, _): return destination.lastPathComponent
        }
    }

    var isUpload: Bool {
        if case .upload = operation { return true }
        return false
    }

    var isDirectory: Bool {
        switch operation {
        case .upload(_, _, let isDirectory, _): return isDirectory
        case .download(let file, _, _): return file.isDirectory
        }
    }

    var direction: String { isUpload ? L10n.text("上传") : L10n.text("下载") }

    var location: String {
        switch operation {
        case .upload(_, let directory, _, _): return directory
        case .download(_, let destination, _): return destination.deletingLastPathComponent().path
        }
    }

    var downloadDestination: URL? {
        if case .download(_, let destination, _) = operation { return destination }
        return nil
    }

    var downloadCheckpoint: DownloadCheckpoint? {
        guard case .download(let file, let destination, _) = operation,
              !file.isDirectory, file.size >= DownloadCheckpoint.minimumSize else { return nil }
        return DownloadCheckpoint(destination: destination, id: id)
    }

    var folderDownloadCheckpoint: FolderDownloadCheckpoint? {
        guard isDirectory, let destination = downloadDestination else { return nil }
        return FolderDownloadCheckpoint(destination: destination, id: id)
    }

    mutating func restoreDownloadProgress() {
        guard let checkpoint = downloadCheckpoint, case .download(let file, _, _) = operation else { return }
        total = file.size
        bytes = min(checkpoint.savedBytes, file.size)
    }
}

@MainActor
final class TransferQueue: ObservableObject {
    static let autoResumeKey = "autoResumeTransfersOnReconnect"
    @Published private(set) var items: [QueuedTransfer] = []
    @Published private(set) var connection: TransferConnection?
    @Published private(set) var storageIssue: String?
    @Published private(set) var isEditingRemotePath = false
    private(set) var showsRestoredItems = false
    private(set) var visibleActiveID: UUID?
    var didUpload: ((QueuedTransfer, TransferConnection) -> Void)?
    let didDownload = PassthroughSubject<URL, Never>()
    private let store: TransferQueueStore
    private let preferences: UserDefaults
    private var canWriteStore = true
    private var delayedProgressSave: Task<Void, Never>?
    private var pendingSnapshot: [QueuedTransfer]?
    private var persistenceTask: Task<Void, Never>?
    private var active: Task<Void, Never>?
    private var interruption: String?
    private var interruptedByConnectionLoss = false
    private var resumeOnNextStart = false
    private var automaticRetryIDs: Set<UUID> = []
    private var checkingPendingMove = false
    private var cleaningUploads: Set<UUID> = []

    init(storageURL: URL = TransferQueueStore.applicationURL, preferences: UserDefaults = .standard) {
        store = TransferQueueStore(url: storageURL)
        self.preferences = preferences
        do {
            items = try store.load().map { stored in
                var item = stored
                if stored.state.isInQueue || stored.state.canRetryInBulk || stored.state == .paused {
                    item.restoreDownloadProgress()
                }
                if stored.state == .pausing {
                    item.state = .paused
                    return item
                }
                guard stored.state.isInQueue else { return item }
                if stored.state == .cancelling && stored.detail == nil {
                    try? item.downloadCheckpoint?.discard()
                    try? item.folderDownloadCheckpoint?.discard()
                    item.restoreDownloadProgress()
                    item.state = .cancelled
                    return item
                }
                item.state = .interrupted
                item.detail = stored.state == .committing
                    ? "应用退出时正在保存，请先检查目标位置。"
                    : "上次退出时传输未完成，重开后可重试。"
                return item
            }
            showsRestoredItems = !items.isEmpty
        } catch {
            canWriteStore = false
            storageIssue = "无法读取上次保存的传输队列。原记录已保留。请修复记录后重新打开应用。"
        }
    }

    var reservedDownloadPaths: Set<String> {
        Set(items.filter { $0.state.isInQueue }.compactMap(\.downloadDestination).map(LocalFileDestination.key))
    }

    var unfinishedCount: Int { items.filter { $0.state.canRetryInBulk }.count }

    var retryableUnfinishedCount: Int {
        items.filter { $0.state.canRetryInBulk && canRetry($0) }.count
    }

    func connect(_ connection: TransferConnection, checkMoveFirst: Bool = false) {
        if self.connection != connection { resumeOnNextStart = true }
        self.connection = connection
        checkingPendingMove = checkMoveFirst
        if !checkMoveFirst { startNext() }
    }

    func beginPendingMoveCheck(on connection: TransferConnection) {
        guard self.connection == connection else { return }
        checkingPendingMove = true
    }

    func finishPendingMoveCheck(on connection: TransferConnection) {
        guard self.connection == connection else { return }
        checkingPendingMove = false
        startNext()
    }

    func enqueue(_ batch: [QueuedTransfer]) {
        guard !isEditingRemotePath, !checkingPendingMove, let connection, !batch.isEmpty,
              batch.allSatisfy({ $0.deviceID == connection.deviceID }) else { return }
        items.append(contentsOf: batch)
        save()
        startNext()
    }

    func pause(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state.canPause else { return }
        items[index].resumeAfterReconnect = nil
        automaticRetryIDs.remove(id)
        if id == visibleActiveID {
            items[index].state = .pausing
            active?.cancel()
        } else {
            items[index].state = .paused
        }
        save()
    }

    func canContinue(_ item: QueuedTransfer) -> Bool {
        item.state == .paused && canStart(item)
    }

    func continueTransfer(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), canContinue(items[index]) else { return }
        resetForRetry(at: index)
        save()
        startNext()
    }

    func cancel(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state.canCancel else { return }
        automaticRetryIDs.remove(id)
        if id == visibleActiveID {
            items[index].state = .cancelling
            active?.cancel()
        } else {
            items[index].state = .cancelled
            items[index].folderProgress = nil
            discardDownload(at: index)
            cleanUpload(items[index], remove: false)
        }
        save()
    }

    func disconnect(reason: String, connectionLost: Bool = false) {
        connection = nil
        checkingPendingMove = false
        resumeOnNextStart = false
        automaticRetryIDs.removeAll()
        var changed = false
        for index in items.indices where items[index].state == .waiting {
            items[index].state = .interrupted
            items[index].detail = reason
            items[index].resumeAfterReconnect = connectionLost
            changed = true
        }
        if let index = items.firstIndex(where: { $0.id == visibleActiveID }), items[index].state.isReading {
            interruption = reason
            interruptedByConnectionLoss = connectionLost
            items[index].state = .cancelling
            items[index].detail = reason
            items[index].resumeAfterReconnect = connectionLost
            active?.cancel()
            changed = true
        }
        if changed { save() }
    }

    func canRetry(_ item: QueuedTransfer) -> Bool {
        item.state.canRetry && canStart(item)
    }

    private func canStart(_ item: QueuedTransfer) -> Bool {
        guard !isEditingRemotePath, !checkingPendingMove, item.deviceID == connection?.deviceID,
              !cleaningUploads.contains(item.id) else { return false }
        return !item.isUpload || !items.contains {
            $0.state.isInQueue && $0.isUpload && $0.deviceID == item.deviceID &&
                $0.location == item.location && $0.name == item.name
        }
    }

    func withRemotePathEdit(on connection: TransferConnection, edit: ([String]) async throws -> Void) async throws {
        guard self.connection == connection, !isEditingRemotePath else {
            throw HubError.message("设备或文件夹已变化，请重新打开操作。")
        }
        isEditingRemotePath = true
        defer {
            isEditingRemotePath = false
            startNext()
        }
        try await edit(protectedRemotePaths(for: connection))
    }

    func protectedRemotePaths(for connection: TransferConnection) -> [String] {
        items.flatMap { item -> [String] in
            guard item.deviceID == connection.deviceID,
                  item.state.isInQueue || item.state == .paused || cleaningUploads.contains(item.id) else { return [] }
            switch item.operation {
            case .upload(let local, let directory, let isDirectory, _):
                var paths = [directory + (directory.hasSuffix("/") ? "" : "/") + local.lastPathComponent]
                if let id = item.uploadStagingID,
                   let stage = try? connection.client.uploadStagingPath(directory: directory, id: id) {
                    paths.append(stage)
                }
                if let id = item.uploadResumeID {
                    if isDirectory {
                        paths.append(ADBClient.uploadFolderStagingPath(directory: directory, id: id))
                    } else if let checkpoint = try? UploadCheckpoint(directory: directory, id: id) {
                        paths.append(checkpoint.path)
                    }
                }
                return paths
            case .download(let file, _, _):
                return [file.path]
            }
        }
    }

    func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), canRetry(items[index]) else { return }
        resetForRetry(at: index)
        save()
        startNext()
    }

    func retryUnfinished() {
        queueUnfinished { _ in true }
        startNext()
    }

    private func queueUnfinished(automatically: Bool = false, matching predicate: (QueuedTransfer) -> Bool) {
        var changed = false
        for index in items.indices where items[index].state.canRetryInBulk && predicate(items[index]) && canRetry(items[index]) {
            resetForRetry(at: index)
            if automatically { automaticRetryIDs.insert(items[index].id) }
            changed = true
        }
        if changed { save() }
    }

    private func resetForRetry(at index: Int) {
        switch items[index].operation {
        case .upload(let local, let directory, let isDirectory, _):
            items[index].operation = .upload(local: local, directory: directory, isDirectory: isDirectory, replaceExisting: false)
        case .download(let file, let destination, _):
            items[index].operation = downloadWithoutReplacing(file, destination: destination)
        }
        if items[index].uploadResumeID == nil && items[index].folderDownloadCheckpoint == nil { items[index].bytes = 0 }
        items[index].restoreDownloadProgress()
        items[index].detail = nil
        items[index].resumeAfterReconnect = nil
        items[index].state = .waiting
    }

    func waitForActive() async {
        await active?.value
        await flushPersistence()
    }

    func flushPersistence() async {
        if delayedProgressSave != nil || (persistenceTask == nil && storageIssue != nil) { save() }
        await persistenceTask?.value
    }

    private func requirePersistence() async throws {
        await flushPersistence()
        if let storageIssue { throw HubError.message(storageIssue) }
        try Task.checkCancellation()
    }

    func clearFinished() {
        for index in items.indices.reversed() where items[index].state.canClear {
            if items[index].uploadResumeID != nil || items[index].uploadStagingID != nil {
                cleanUpload(items[index], remove: true)
            } else if discardDownload(at: index) {
                items.remove(at: index)
            }
        }
        save()
    }

    private func cleanUpload(_ item: QueuedTransfer, remove: Bool) {
        guard let id = item.uploadResumeID ?? item.uploadStagingID, !cleaningUploads.contains(item.id),
              case .upload(_, let directory, _, _) = item.operation,
              let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        guard let connection, connection.deviceID == item.deviceID else {
            items[index].detail = "重新连接原手机后，可清理上传临时文件。"
            return
        }
        cleaningUploads.insert(item.id)
        Task {
            do {
                if item.uploadResumeID == nil {
                    try await connection.client.removeUploadStaging(serial: connection.serial, directory: directory, id: id)
                } else if item.isDirectory {
                    try await connection.client.discardUploadedFolder(serial: connection.serial, directory: directory, id: id)
                } else {
                    let checkpoint = try UploadCheckpoint(directory: directory, id: id)
                    try await connection.client.discardUploadCheckpoint(serial: connection.serial, checkpoint: checkpoint)
                }
                if let index = items.firstIndex(where: { $0.id == item.id }) {
                    if remove {
                        items.remove(at: index)
                    } else {
                        items[index].uploadResumeID = nil
                        items[index].uploadStagingID = nil
                        items[index].bytes = 0
                        items[index].detail = nil
                    }
                }
            } catch {
                if let index = items.firstIndex(where: { $0.id == item.id }) {
                    items[index].detail = "无法清理手机上的上传临时文件。\(TransferFailure.message(for: error, uploading: true))"
                }
            }
            cleaningUploads.remove(item.id)
            save()
        }
    }

    @discardableResult
    private func discardDownload(at index: Int) -> Bool {
        do {
            try items[index].downloadCheckpoint?.discard()
            if let folder = items[index].folderDownloadCheckpoint {
                try folder.discard()
                items[index].bytes = 0
            }
            items[index].restoreDownloadProgress()
            return true
        } catch {
            items[index].detail = "无法清理下载临时文件。请检查保存目录的权限后再清除任务。"
            return false
        }
    }

    // Progress can change many times per file. Keep the current UI value and persist at most once per interval.
    private func saveProgress() {
        guard canWriteStore, delayedProgressSave == nil else { return }
        delayedProgressSave = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            self?.save()
        }
    }

    private func save() {
        guard canWriteStore else { return }
        delayedProgressSave?.cancel()
        delayedProgressSave = nil
        // A newer snapshot supersedes any waiting snapshot. The write already in flight finishes first.
        pendingSnapshot = items
        guard persistenceTask == nil else { return }
        persistenceTask = Task {
            while let snapshot = pendingSnapshot {
                pendingSnapshot = nil
                let issue: String?
                do {
                    try await store.saveInBackground(snapshot)
                    issue = nil
                } catch {
                    issue = "传输队列未能保存到 Mac。请检查存储空间和写入权限。"
                }
                if storageIssue != issue { storageIssue = issue }
            }
            persistenceTask = nil
        }
    }

    private func startNext() {
        guard active == nil, !isEditingRemotePath, !checkingPendingMove, let connection else { return }
        if resumeOnNextStart {
            resumeOnNextStart = false
            if preferences.bool(forKey: Self.autoResumeKey) {
                queueUnfinished(automatically: true) { $0.state == .interrupted && $0.resumeAfterReconnect == true }
            }
        }
        guard let index = items.firstIndex(where: { $0.state == .waiting && $0.deviceID == connection.deviceID }) else { return }
        if case .download(let file, let destination, false) = items[index].operation,
           FileManager.default.fileExists(atPath: destination.path) {
            items[index].operation = downloadWithoutReplacing(file, destination: destination)
        }
        let transfer = items[index]
        let id = transfer.id
        let automatic = automaticRetryIDs.remove(id) != nil
        visibleActiveID = id
        items[index].state = .transferring
        save()
        active = Task { [self] in
            let report: @Sendable (TransferProgress) async -> Void = { [weak self] progress in
                await self?.update(progress, id: id)
            }
            do {
                try Task.checkCancellation()
                try await run(transfer, on: connection, automatic: automatic, progress: report)
                finish(id, state: .completed)
                if transfer.isUpload { didUpload?(transfer, connection) }
                else if let destination = transfer.downloadDestination { didDownload.send(destination) }
            } catch {
                let cleanup = error as? UploadCleanupError
                let failure = cleanup?.transferError ?? error
                let cause = TransferFailure.message(for: failure, uploading: transfer.isUpload)
                let needsUser = TransferFailure.requiresUserAction(cause)
                var disconnected = TransferFailure.isConnectionLoss(failure)
                if !disconnected, !needsUser, !Task.isCancelled, interruption == nil,
                   let devices = try? await connection.client.devices(timeout: 3) {
                    disconnected = !devices.contains { $0.serial == connection.serial && $0.isOnline }
                }
                if items.first(where: { $0.id == id })?.state == .pausing {
                    finish(id, state: .paused, detail: cleanup?.localizedDescription, keepUploadStaging: cleanup != nil)
                } else if let interruption {
                    if needsUser {
                        finish(id, state: .failed, detail: cause, keepUploadStaging: cleanup != nil)
                    } else {
                        finish(id, state: .interrupted, detail: [interruption, cleanup?.localizedDescription].compactMap { $0 }.joined(separator: " "),
                               keepUploadStaging: cleanup != nil, reconnect: interruptedByConnectionLoss)
                    }
                } else if Task.isCancelled && cleanup == nil {
                    finish(id, state: .cancelled)
                } else if !Task.isCancelled && disconnected && !needsUser {
                    finish(id, state: .interrupted, detail: "手机连接中断。重新连接同一台手机后可继续。",
                           keepUploadStaging: cleanup != nil, reconnect: true)
                } else {
                    finish(id, state: .failed, detail: [cause, cleanup?.localizedDescription].compactMap { $0 }.joined(separator: " "),
                           keepUploadStaging: cleanup != nil)
                }
            }
            interruption = nil
            interruptedByConnectionLoss = false
            active = nil
            visibleActiveID = nil
            startNext()
        }
    }

    private func run(_ transfer: QueuedTransfer, on connection: TransferConnection, automatic: Bool,
                     progress: @escaping @Sendable (TransferProgress) async -> Void) async throws {
        let client = connection.client
        let serial = connection.serial
        let beforeCommit: @Sendable () async throws -> Void = { [self] in
            try await requirePersistence()
        }
        switch transfer.operation {
        case .upload(let local, let directory, let isDirectory, let replace):
            if let previous = transfer.uploadStagingID {
                try await requirePersistence()
                try await client.removeUploadStaging(serial: serial, directory: directory, id: previous)
                if let index = items.firstIndex(where: { $0.id == transfer.id }) {
                    items[index].uploadStagingID = nil
                    save()
                }
            }
            try Task.checkCancellation()
            guard FileManager.default.fileExists(atPath: local.path) else {
                throw HubError.message("Mac 上的源项目已移动或删除。请恢复原路径，或重新选择要上传的项目。")
            }
            if isDirectory {
                let resumeID = transfer.uploadResumeID ?? transfer.id
                if let index = items.firstIndex(where: { $0.id == transfer.id }) {
                    items[index].uploadResumeID = resumeID
                    save()
                }
                try await requirePersistence()
                try await client.uploadFolder(serial: serial, local: local, directory: directory,
                                              checkpointID: resumeID, automatic: automatic, beforeCommit: beforeCommit, progress: progress)
                return
            }
            let size = try local.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if transfer.uploadResumeID != nil || Int64(size) >= UploadCheckpoint.minimumSize {
                let resumeID = transfer.uploadResumeID ?? transfer.id
                let checkpoint = try UploadCheckpoint(directory: directory, id: resumeID)
                if let index = items.firstIndex(where: { $0.id == transfer.id }) {
                    items[index].uploadResumeID = resumeID
                    save()
                }
                try await requirePersistence()
                try await client.uploadResumable(serial: serial, local: local, directory: directory, replaceExisting: replace,
                                                 checkpoint: checkpoint, automatic: automatic, beforeCommit: beforeCommit, progress: progress)
                return
            }
            let stagingID = UUID()
            if let index = items.firstIndex(where: { $0.id == transfer.id }) {
                items[index].uploadStagingID = stagingID
                save()
            }
            try await requirePersistence()
            try await client.upload(serial: serial, local: local, directory: directory, replaceExisting: replace,
                                    stagingID: stagingID, beforeCommit: beforeCommit, progress: progress)
        case .download(let file, let destination, let replace):
            var isDirectory: ObjCBool = false
            let parent = destination.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw HubError.message("Mac 上的保存文件夹不存在。请恢复原路径或重新选择下载位置。")
            }
            try await requirePersistence()
            if file.isDirectory {
                try await client.downloadFolder(serial: serial, remote: file.path, destination: destination,
                                                checkpointID: transfer.id, automatic: automatic, beforeCommit: beforeCommit, progress: progress)
            } else {
                try await client.downloadFile(serial: serial, file: file, destination: destination, replaceExisting: replace,
                                              checkpoint: transfer.downloadCheckpoint, automatic: automatic, beforeCommit: beforeCommit, progress: progress)
            }
        }
    }

    private func downloadWithoutReplacing(_ file: DeviceFile, destination: URL) -> QueuedTransfer.Operation {
        var reserved = reservedDownloadPaths
        let next = LocalFileDestination.uniqueURL(named: destination.lastPathComponent,
                                                  in: destination.deletingLastPathComponent(), reserving: &reserved)
        return .download(file: file, destination: next, replaceExisting: false)
    }

    private func update(_ progress: TransferProgress, id: UUID) async {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state.isReading else { return }
        var item = items[index]
        switch progress {
        case .transferring(let bytes, let total):
            guard item.bytes != bytes || item.total != total else { return }
            item.bytes = bytes
            item.total = total
            items[index] = item
            if item.uploadResumeID != nil || item.folderDownloadCheckpoint != nil { saveProgress() }
        case .folder(let folder, let bytes, let total):
            guard item.folderProgress != folder || item.bytes != bytes || item.total != total else { return }
            item.folderProgress = folder
            item.bytes = bytes
            item.total = total
            items[index] = item
            saveProgress()
        case .verifying(let total):
            item.state = .verifying
            item.bytes = total
            item.total = total
            items[index] = item
            save()
        case .committing(let total):
            item.state = .committing
            item.bytes = total
            item.total = total
            items[index] = item
            save()
        }
    }

    private func finish(_ id: UUID, state: QueuedTransfer.State, detail: String? = nil,
                        keepUploadStaging: Bool = false, reconnect: Bool = false) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = state
        items[index].detail = detail
        items[index].resumeAfterReconnect = reconnect ? true : nil
        if !keepUploadStaging { items[index].uploadStagingID = nil }
        if state == .completed { items[index].uploadResumeID = nil }
        if state == .cancelled {
            items[index].folderProgress = nil
            discardDownload(at: index)
            cleanUpload(items[index], remove: false)
        }
        if state.canRetryInBulk || state == .paused { items[index].restoreDownloadProgress() }
        save()
    }
}
