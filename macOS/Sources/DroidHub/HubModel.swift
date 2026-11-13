import AppKit
import Combine
import SwiftUI
import DroidHubCore

enum MirroringState: Equatable {
    case idle, starting, running(processID: Int32), stopping
}

struct DeviceInfoState {
    var info: AndroidDeviceInfo?
    var updatedAt: Date?
    var loading = false
    var failed = false
}

@MainActor
final class HubModel: ObservableObject {
    @Published var devices: [AndroidDevice] = []
    @Published var selectedSerial: String? {
        didSet {
            if oldValue != selectedSerial {
                let connectionLost = transfers.connection != nil && !devices.contains { $0.serial == oldValue && $0.isOnline }
                resetDevice(connectionLost: connectionLost)
                prepareTransferConnection()
            }
        }
    }
    @Published private(set) var files: [DeviceFile] = [] {
        didSet { fileListRevision = UUID() }
    }
    private(set) var fileListRevision = UUID()
    @Published private(set) var isLoadingDirectory = false
    @Published private(set) var directoryFailure: (path: String, message: String)?
    @Published var path = "/sdcard"
    var deviceSession: UUID { generation }
    @Published private var gallery = GalleryBrowsing()
    @Published private(set) var galleryLoading = false
    @Published private(set) var galleryNotice: String?
    @Published private(set) var photoRefreshID = UUID()
    @Published private(set) var photoLibrary: ADBPhotoLibrary?
    var media: [MediaItem] { gallery.items }
    var photoAlbums: [PhotoAlbum] { gallery.albums }
    var photoAlbumID: String? { gallery.album }
    var showsVideos: Bool { gallery.showsVideos }
    var galleryNoun: String { showsVideos ? L10n.text("视频") : L10n.text("照片") }
    var galleryUnit: String { showsVideos ? L10n.text("个") : L10n.text("张") }
    var hasMorePhotos: Bool { gallery.hasMore }
    var hasMoreAllPhotos: Bool { gallery.hasMoreAll }
    var galleryRevision: UUID? { gallery.revision }
    @Published private(set) var photoExportResult: PhotoExportResult?
    @Published var photoExportProgress: PhotoExportProgress?
    @Published var exportedPhotos: [URL] = []
    @Published private(set) var previewExport: (owner: UUID, filename: String)?
    @Published var busy = false
    @Published var status = L10n.text("连接安卓手机，开始管理文件和照片。")
    @Published var error: String?
    @Published var moveNotice: String?
    @Published var batchRenameNotice: String?
    @Published private(set) var mirroringState = MirroringState.idle
    var mirroring: Bool { mirroringState != .idle }
    var mirrorWindowReady: Bool {
        if case .running = mirroringState { return true }
        return false
    }
    @Published private(set) var screenshotURL: URL?
    @Published private(set) var capturingScreenshot = false
    @Published private(set) var deviceInfoState = DeviceInfoState()
    @Published var adbPath: String {
        didSet {
            if oldValue != adbPath {
                selectedSerial = nil
                devices = []
            }
        }
    }
    @Published var scrcpyPath: String
    let videoPreviewFiles = VideoPreviewFiles()
    let transfers: TransferQueue
    let applications = ApplicationLibraryState()
    private var transferConnectionLookup: Task<Int?, Never>?
    private var transferConnectionObservation: AnyCancellable?
    private var shuttingDown = false
    private var work: Task<Void, Never>?
    private var galleryLoad: Task<Void, Never>?
    private var galleryUser: Int?
    private let galleryCache: GalleryManifestCache
    private var uploadedDirectoryRefresh: Task<Void, Never>?
    private var directoryLoad: Task<Void, Never>?
    private var directoryCache: [String: [DeviceFile]] = [:]
    private var directoryRevision = UUID()
    private var showingCachedDirectory = false
    private var directoryHistory: [String] = []
    private var directoryOffsets: [String: CGFloat] = [:]
    private var mirrorTask: Task<Void, Never>?
    private var screenshotTask: Task<Void, Never>?
    private var deviceInfoTask: Task<Void, Never>?
    @Published private var generation = UUID()
    private var deviceRefreshID = UUID()
    private var trackedADBPath: String?
    private var lastDeviceRefresh: ContinuousClock.Instant?
    private var fileRecordWrite: Task<Void, Error>?
    private let moveBatchStore: RemoteMoveBatchStore
    @Published private var moveSnapshot = RemoteMoveSnapshot()
    private var moveBatches: [RemoteMoveBatch] { moveSnapshot.batches }
    private var moveBatchStoreReadable = true
    private let moveJournal: RemoteMoveJournal
    private var pendingMoves: [PendingRemoteMove] = []
    private var moveJournalReadable = true
    private var moveRecovery: Task<Void, Never>?
    private var drainingRemoteEdit: Task<Void, Never>?

    init(transferStorageURL: URL = TransferQueueStore.applicationURL, transferPreferences: UserDefaults = .standard,
         galleryCache: GalleryManifestCache = .shared) {
        self.galleryCache = galleryCache
        transfers = TransferQueue(storageURL: transferStorageURL, preferences: transferPreferences)
        moveJournal = RemoteMoveJournal(url: transferStorageURL.deletingLastPathComponent().appendingPathComponent("pending-moves.json"))
        moveBatchStore = RemoteMoveBatchStore(url: transferStorageURL.deletingLastPathComponent()
            .appendingPathComponent("move-batches.json"))
        do { moveSnapshot = try moveBatchStore.loadSnapshot() }
        catch { moveBatchStoreReadable = false }
        adbPath = Self.toolPath("adb")
        scrcpyPath = Self.toolPath("scrcpy")
        do { pendingMoves = try moveJournal.load() }
        catch { moveJournalReadable = false }
        transfers.didUpload = { [weak self] upload, connection in
            self?.refreshUploadedDirectory(upload, connection: connection)
        }
        transferConnectionObservation = transfers.$connection.dropFirst().sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private static func toolPath(_ name: String) -> String {
        if let path = UserDefaults.standard.string(forKey: name + "Path"),
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return ADBClient.discover(name) ?? ""
    }
    var selectedDevice: AndroidDevice? { devices.first { $0.serial == selectedSerial } }
    var online: Bool { selectedDevice?.isOnline == true }
    var onlineSerial: String? { online ? selectedSerial : nil }
    var adb: ADBClient { ADBClient(executable: adbPath) }

    func watchDevices() async {
        guard !Task.isCancelled else { return }
        let client = adb
        trackedADBPath = nil
        guard !client.executable.isEmpty else { return }
        while !Task.isCancelled {
            do {
                for try await _ in client.deviceEvents() {
                    guard !Task.isCancelled, client.executable == adbPath else { return }
                    trackedADBPath = client.executable
                    await refreshDevices()
                }
            } catch { /* Periodic refresh remains available. */ }
            if !Task.isCancelled, adbPath == client.executable { trackedADBPath = nil }
            do { try await Task.sleep(nanoseconds: 10_000_000_000) }
            catch { return }
        }
    }

    func pollDevices() async {
        let clock = ContinuousClock()
        while !Task.isCancelled {
            let isFresh = lastDeviceRefresh.map { $0.duration(to: clock.now) < .seconds(30) } ?? false
            if trackedADBPath != adbPath || !isFresh { await refreshDevices() }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    func refreshDevices() async {
        guard !adbPath.isEmpty else { return }
        let client = adb
        let id = UUID()
        deviceRefreshID = id
        do {
            let result = try await client.devices()
            guard !Task.isCancelled, id == deviceRefreshID, client.executable == adbPath else { return }
            lastDeviceRefresh = ContinuousClock().now
            let previous = selectedDevice
            if result != devices { devices = result }
            if let available = result.first(where: \.isOnline), !online {
                // ADB can retain an offline transport while another transport comes online.
                selectedSerial = available.serial
            } else if !result.contains(where: { $0.serial == selectedSerial }) {
                selectedSerial = result.first(where: \.isOnline)?.serial ?? result.first?.serial
            } else if previous?.isOnline == true, !online || previous?.transportID != selectedDevice?.transportID {
                resetDevice(connectionLost: true)
            }
            prepareTransferConnection()
        } catch {
            if !busy, !Task.isCancelled, id == deviceRefreshID, client.executable == adbPath {
                status = L10n.text("设备检测失败：{1}", L10n.diagnostic(error.localizedDescription))
            }
        }
    }

    func selectWirelessDevice(_ device: AndroidDevice) {
        deviceRefreshID = UUID()
        let previous = selectedDevice
        if let index = devices.firstIndex(where: { $0.serial == device.serial }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
        if let previous, previous.serial == device.serial,
           previous.isOnline != device.isOnline || previous.transportID != device.transportID {
            resetDevice(connectionLost: true)
        }
        selectedSerial = device.serial
        prepareTransferConnection()
    }

    private func prepareTransferConnection() {
        guard !shuttingDown, transfers.connection == nil, transferConnectionLookup == nil,
              let device = selectedDevice, device.isOnline else { return }
        let client = adb
        let session = generation
        transferConnectionLookup = Task {
            let started = ContinuousClock.now
            let hardware: String?
            let user: Int?
            do {
                (hardware, user) = try await client.connectionIdentity(for: device)
            } catch {
                guard !Task.isCancelled else { return nil }
                hardware = try? await client.hardwareSerial(for: device)
                user = nil
            }
            _ = await fileRecordWrite?.result
            guard !Task.isCancelled, generation == session else { return nil }
            GalleryMetrics.record("connection_identity", since: started, wireless: device.isWireless)
            transferConnectionLookup = nil
            guard onlineSerial == device.serial, selectedDevice?.transportID == device.transportID,
                  adbPath == client.executable else { return nil }
            let identity: TransferDeviceID
            if let hardware, !device.serial.hasPrefix("emulator-") {
                identity = .hardware(TransferDeviceID.hardwareFingerprint(hardware))
            } else if !device.isWireless, !device.serial.hasPrefix("emulator-") {
                identity = .usb(device.serial)
            } else {
                identity = .session(session)
            }
            let connection = TransferConnection(deviceID: identity, serial: device.serial, executable: client.executable)
            let hasPendingMove = pendingMoves.contains { $0.device == identity }
            let hasInterruptedBatch = moveBatches.contains { $0.device == identity && $0.checking }
            let hasDeletionToCheck = moveSnapshot.deletions?.contains { $0.device == identity && $0.checkIndex != nil } == true
            transfers.connect(connection, checkMoveFirst: hasPendingMove || hasInterruptedBatch || hasDeletionToCheck)
            if hasPendingMove { recoverRemoteMove(on: connection) }
            else if hasInterruptedBatch { recoverBatchMove(on: connection) }
            else if hasDeletionToCheck { reconcileTrashDeletion(on: connection) }
            return user
        }
    }

    private func resetDevice(connectionLost: Bool = false,
                             transferReason: String = L10n.text("设备已断开或切换。重新连接原手机后可重试。")) {
        if transfers.isEditingRemotePath { drainingRemoteEdit = work ?? moveRecovery ?? drainingRemoteEdit }
        generation = UUID()
        applications.reset()
        transferConnectionLookup?.cancel()
        transferConnectionLookup = nil
        moveRecovery?.cancel()
        moveRecovery = nil
        transfers.disconnect(reason: transferReason, connectionLost: connectionLost)
        uploadedDirectoryRefresh?.cancel()
        cancelDirectoryLoad()
        directoryFailure = nil
        invalidateDirectoryCache()
        directoryHistory.removeAll()
        directoryOffsets.removeAll()
        work?.cancel(); work = nil; busy = false
        mirrorTask?.cancel(); mirrorTask = nil; mirroringState = .idle
        screenshotTask?.cancel(); screenshotTask = nil; capturingScreenshot = false; screenshotURL = nil
        deviceInfoTask?.cancel(); deviceInfoTask = nil; deviceInfoState = DeviceInfoState()
        galleryLoad?.cancel(); galleryLoad = nil
        galleryLoading = false; galleryNotice = nil
        resetGallery()
        photoExportProgress = nil
        previewExport = nil
        files = []; path = "/sdcard"
        photoExportResult = nil; exportedPhotos = []
    }

    private func resetGallery() {
        if let id = photoLibrary?.cacheID {
            Task { await PhotoImagePipeline.shared.invalidate(clientID: id) }
        }
        galleryUser = nil
        photoLibrary = nil
        gallery = GalleryBrowsing()
    }

    private func requirePhotoLibrary(_ library: ADBPhotoLibrary) throws {
        try Task.checkCancellation()
        guard photoLibrary?.cacheID == library.cacheID else { throw CancellationError() }
    }

    func shutdown() async {
        let pendingWork = work
        let pendingMoveRecovery = moveRecovery
        let pendingFileRecord = fileRecordWrite
        let pendingGallery = galleryLoad
        let pendingApplicationDetails = applications.detailsWork
        let pendingDirectoryLoad = directoryLoad
        let pendingMirror = mirrorTask
        let pendingScreenshot = screenshotTask
        let pendingDeviceInfo = deviceInfoTask
        shuttingDown = true
        resetDevice(transferReason: L10n.text("应用退出时传输未完成，重开后可重试。"))
        await videoPreviewFiles.shutdown()
        await pendingWork?.value
        await pendingMoveRecovery?.value
        _ = await pendingFileRecord?.result
        await pendingGallery?.value
        await pendingApplicationDetails?.value
        await pendingDirectoryLoad?.value
        await pendingMirror?.value
        await pendingScreenshot?.value
        await pendingDeviceInfo?.value
        await transfers.waitForActive()
    }

    func perform(_ label: String, reportsCompletion: Bool = true, operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; status = label
        let current = generation
        work = Task {
            do {
                try await operation()
                try Task.checkCancellation()
                if current == generation, reportsCompletion { status = L10n.text("{1} · {2}", label, L10n.text("完成")) }
            } catch {
                if current == generation {
                    if Task.isCancelled {
                        status = L10n.text("任务已取消")
                    } else {
                        self.error = L10n.diagnostic(error.localizedDescription)
                        status = L10n.text("操作失败")
                    }
                }
            }
            if current == generation { busy = false; work = nil }
        }
    }

    func cancel() {
        if let work { work.cancel() }
        else { cancelDirectoryLoad() }
    }

    func waitForForegroundWork(in session: UUID) async {
        while let pending = work {
            await pending.value
            guard !Task.isCancelled, deviceSession == session else { return }
        }
    }

    func hardwareFingerprint(in session: UUID) async -> String? {
        _ = await transferConnectionLookup?.value
        guard !Task.isCancelled, deviceSession == session,
              case .hardware(let fingerprint) = transfers.connection?.deviceID else { return nil }
        return fingerprint
    }

    func loadFilesWhenReady(for serial: String) async {
        while let pendingWork = work {
            await pendingWork.value
            guard !Task.isCancelled, onlineSerial == serial else { return }
        }
        guard !Task.isCancelled, onlineSerial == serial,
              !isLoadingDirectory, !hasLoadedDirectory else { return }
        loadFiles()
    }

    func loadFiles(_ destination: String? = nil) {
        guard !busy, let serial = onlineSerial else { return }
        let target = (destination ?? path) as NSString
        let normalized = target.standardizingPath
        guard !TrashEntry.isStorage(normalized) else {
            error = L10n.text("请在「回收站」中查看或恢复这些项目。")
            return
        }
        let client = adb
        let session = generation
        let revision = directoryRevision
        directoryLoad?.cancel()
        uploadedDirectoryRefresh?.cancel()
        directoryFailure = nil
        isLoadingDirectory = true
        let cached = directoryCache[normalized]
        if let cached, normalized != path {
            showingCachedDirectory = true
            path = normalized
            files = cached
        }
        directoryLoad = Task {
            defer {
                if !Task.isCancelled, generation == session {
                    isLoadingDirectory = false
                    directoryLoad = nil
                }
            }
            do {
                let result = try await client.files(serial: serial, path: normalized)
                try Task.checkCancellation()
                guard generation == session else { return }
                if directoryRevision != revision {
                    if busy { cancelDirectoryLoad() }
                    else { loadFiles(normalized) }
                    return
                }
                if path != normalized { path = normalized }
                if files != result { files = result }
                showingCachedDirectory = false
                rememberDirectory(normalized, files: result)
            } catch {
                guard !Task.isCancelled, generation == session else { return }
                directoryCache[normalized] = nil
                if showingCachedDirectory {
                    files = []
                    showingCachedDirectory = false
                }
                self.directoryFailure = (normalized, L10n.diagnostic(error.localizedDescription))
            }
        }
    }

    private func cancelDirectoryLoad() {
        directoryLoad?.cancel()
        directoryLoad = nil
        if showingCachedDirectory {
            files = []
            showingCachedDirectory = false
        }
        isLoadingDirectory = false
    }

    private func invalidateDirectoryCache() {
        directoryRevision = UUID()
        directoryCache.removeAll()
    }

    private func rememberDirectory(_ directory: String, files: [DeviceFile]) {
        directoryHistory.removeAll { $0 == directory }
        directoryHistory.append(directory)
        directoryCache[directory] = files
        if directoryHistory.count > 12 {
            let oldest = directoryHistory.removeFirst()
            directoryCache[oldest] = nil
            directoryOffsets[oldest] = nil
        }
    }

    @discardableResult
    private func refreshCurrentDirectory(_ directory: String, on connection: TransferConnection,
                                         session: UUID) async throws -> [DeviceFile]? {
        let revision = fileListRevision
        func isCurrent() -> Bool {
            !Task.isCancelled && generation == session && transfers.connection == connection &&
                path == directory && !isLoadingDirectory && fileListRevision == revision
        }
        guard isCurrent() else { return nil }
        do {
            let result = try await connection.client.files(serial: connection.serial, path: directory)
            guard isCurrent() else { return nil }
            rememberDirectory(directory, files: result)
            files = result
            return result
        } catch {
            guard isCurrent() else { return nil }
            throw error
        }
    }

    func directoryOffset(for directory: String) -> CGFloat { directoryOffsets[directory] ?? 0 }
    var hasLoadedDirectory: Bool { directoryCache[path] != nil }

    func rememberDirectoryOffset(_ offset: CGFloat, for directory: String, session: UUID) {
        guard generation == session, directoryHistory.contains(directory) else { return }
        directoryOffsets[directory] = offset
    }

    struct UploadTarget: Equatable {
        let session: UUID
        let serial: String
        let directory: String
        let executable: String
    }

    var uploadTarget: UploadTarget? {
        guard let connection = transfers.connection, onlineSerial == connection.serial,
              !busy, !isLoadingDirectory, moveRecovery == nil, fileRecordWrite == nil else { return nil }
        return UploadTarget(session: generation, serial: connection.serial, directory: path, executable: connection.executable)
    }

    func editRemoteFile(_ file: DeviceFile?, name: String, in target: UploadTarget, didEdit: @escaping (DeviceFile) -> Void) {
        guard uploadTarget == target, let connection = transfers.connection,
              file.map({ files.contains($0) }) != false else {
            error = L10n.text("设备、目录或所选项目已变化，请刷新后重试。")
            return
        }
        if let batch = moveBatch, batch.trash != nil, batch.checking {
            error = L10n.text("请先核对未完成的回收站操作。")
            return
        }
        let finalName: String
        do {
            if let file { finalName = try RemoteEntryName.renamed(file, stem: name) }
            else { try RemoteEntryName.validate(name); finalName = name }
        } catch let failure {
            error = L10n.diagnostic(failure.localizedDescription)
            return
        }
        if let file, file.name == finalName {
            didEdit(file)
            return
        }
        uploadedDirectoryRefresh?.cancel()
        invalidateDirectoryCache()
        perform(file == nil ? L10n.text("新建文件夹") : L10n.text("重命名")) {
            let client = connection.client
            let destination = try ADBClient.entryPath(parent: target.directory, name: finalName)
            try await self.transfers.withRemotePathEdit(on: connection) { protected in
                let affected = [destination] + (file.map { [$0.path] } ?? [])
                try await self.checkRemoteEdit(affected: affected, protected: protected, connection: connection)
                try Task.checkCancellation()
                guard self.generation == target.session, self.transfers.connection == connection,
                      self.path == target.directory else { throw CancellationError() }
                do {
                    if let file {
                        try await client.renameEntry(serial: target.serial, parent: target.directory, file: file, stem: name)
                    } else {
                        try await client.createDirectory(serial: target.serial, parent: target.directory, name: finalName)
                    }
                } catch {
                    let failure = TransferFailure.message(for: error, uploading: true)
                    if failure.contains("没有权限") || failure.lowercased().contains("permission") {
                        throw HubError.message(L10n.text("没有权限修改这个手机目录。请在可写目录中重试。"))
                    }
                    throw HubError.message(L10n.diagnostic(failure))
                }
                try Task.checkCancellation()
                do {
                    guard let result = try await self.refreshCurrentDirectory(
                        target.directory, on: connection, session: target.session
                    ) else { return }
                    if let updated = result.first(where: { $0.path == destination }) { didEdit(updated) }
                } catch {
                    try Task.checkCancellation()
                    throw HubError.message(L10n.text("手机上的操作已完成，但列表刷新失败。请手动刷新目录。"))
                }
            }
        }
    }

    func moveDirectories(at directory: String, in target: UploadTarget) async throws -> [DeviceFile] {
        guard !TrashEntry.isStorage(directory) else { throw HubError.message(L10n.text("请选择回收站以外的目录。")) }
        guard uploadTarget == target else { throw HubError.message(L10n.text("设备或源目录已变化，请重新打开移动窗口。")) }
        let files = try await ADBClient(executable: target.executable).files(serial: target.serial, path: directory)
        try Task.checkCancellation()
        guard uploadTarget == target else { throw CancellationError() }
        return files.filter { $0.isDirectory && !TrashEntry.isStorage($0.path) }
    }

    func moveRemoteFile(_ file: DeviceFile, to destination: String, in target: UploadTarget) {
        guard uploadTarget == target, let connection = transfers.connection, files.contains(file) else {
            error = L10n.text("设备、目录或所选项目已变化，请刷新后重试。")
            return
        }
        guard canStartJournaledEdit(on: connection) else { return }
        uploadedDirectoryRefresh?.cancel()
        invalidateDirectoryCache()
        perform(L10n.text("移动项目")) {
            try await self.transfers.withRemotePathEdit(on: connection) { protected in
                let client = connection.client
                let move = try await client.prepareMove(serial: connection.serial, file: file,
                                                        from: target.directory, to: destination)
                try await self.checkRemoteEdit(affected: [move.source, move.destination], protected: protected,
                                               connection: connection)
                try Task.checkCancellation()
                guard self.generation == target.session, self.transfers.connection == connection,
                      self.path == target.directory else { throw CancellationError() }
                try await self.applyJournaledMove(move, on: connection, session: target.session)
                do {
                    try await self.refreshCurrentDirectory(target.directory, on: connection, session: target.session)
                } catch {
                    try Task.checkCancellation()
                    throw HubError.message(L10n.text("移动已完成，但列表刷新失败。请手动刷新源目录。"))
                }
            }
        }
    }

    var moveBatch: RemoteMoveBatch? {
        guard let device = transfers.connection?.deviceID else { return nil }
        return moveBatches.first { $0.device == device }
    }

    var canManageMoveBatch: Bool { !busy && moveRecovery == nil && fileRecordWrite == nil && moveBatch != nil }

    func previewBatchMove(_ selection: [DeviceFile], to destination: String, in target: UploadTarget) async throws -> [BatchMoveRow] {
        guard uploadTarget == target, let connection = transfers.connection,
              selection.allSatisfy(files.contains) else {
            throw HubError.message(L10n.text("设备、目录或所选项目已变化，请重新打开移动窗口。"))
        }
        var rows = try await connection.client.previewBatchMove(serial: connection.serial, files: selection,
                                                                 from: target.directory, to: destination)
        let protected = transfers.protectedRemotePaths(for: connection)
        if !protected.isEmpty {
            let canonical = try await canonicalProtectedPaths(protected, connection: connection)
            for index in rows.indices {
                guard let move = rows[index].move else { continue }
                if Self.overlapsProtectedMove(move, protected: canonical) {
                    rows[index].issue = L10n.text("涉及正在处理或已暂停的传输任务。")
                }
            }
        }
        try Task.checkCancellation()
        guard uploadTarget == target else { throw CancellationError() }
        return rows
    }

    func startBatchMove(_ rows: [BatchMoveRow], in target: UploadTarget) {
        guard uploadTarget == target, let connection = transfers.connection, rows.count > 1,
              rows.allSatisfy({ $0.issue == nil && files.contains($0.file) }) else {
            error = L10n.text("项目或目录已变化，请重新预览。")
            return
        }
        let moves = rows.compactMap(\.move)
        guard moves.count == rows.count, let first = moves.first,
              canStartJournaledEdit(on: connection) else { return }
        let destination = (first.destination as NSString).deletingLastPathComponent
        runBatchMove(RemoteMoveBatch(device: connection.deviceID, destination: destination, moves: moves),
                     on: connection, retry: false)
    }

    func retryBatchMove() {
        guard canManageMoveBatch, let batch = moveBatch, let connection = transfers.connection, !batch.isFinished else { return }
        if batch.checking {
            recoverBatchMove(on: connection)
        } else {
            runBatchMove(batch, on: connection, retry: true)
        }
    }

    func clearMoveBatch() {
        guard canManageMoveBatch, let batch = moveBatch, batch.canDiscard else { return }
        var snapshot = moveSnapshot
        snapshot.batches.removeAll { $0.device == batch.device }
        let updated = snapshot
        perform(L10n.text("更新文件操作记录"), reportsCompletion: false) {
            try await self.saveMoveSnapshot(updated)
        }
    }

    var trashEntries: [TrashEntry] {
        guard let device = transfers.connection?.deviceID else { return [] }
        return moveSnapshot.trash.filter { $0.device == device }.sorted { $0.date > $1.date }
    }

    func moveToTrash(_ selection: [DeviceFile], in target: UploadTarget) {
        let available = Set(files)
        guard uploadTarget == target, let connection = transfers.connection, !selection.isEmpty,
              selection.allSatisfy({ available.contains($0) && !TrashEntry.isStorage($0.path) }) else {
            error = L10n.text("设备、目录或所选项目已变化，请刷新后重试。")
            return
        }
        guard canStartJournaledEdit(on: connection) else { return }
        let rootName = ".droidhub-trash-" + moveSnapshot.namespace.uuidString.lowercased()
        runBatchMove(on: connection, label: TrashAction.put.title, retry: false) { protected in
            let client = connection.client
            let serial = connection.serial
            let canonical = try await client.canonicalPaths(serial: serial, paths: [target.directory])
            guard let parent = canonical[target.directory], !TrashEntry.isStorage(parent) else {
                throw HubError.message(L10n.text("无法确认原目录。"))
            }
            let originals = try selection.map { try ADBClient.entryPath(parent: parent, name: $0.name) }
            try await self.checkRemoteEdit(affected: originals, protected: protected, connection: connection)
            let root = try await client.trashStorage(serial: serial, parent: parent, name: rootName)
            let date = Date()
            let entries = try zip(selection, originals).map { file, original in
                let id = UUID()
                let stored = try ADBClient.entryPath(parent: root, name: id.uuidString)
                return TrashEntry(id: id, device: connection.deviceID, name: file.name, original: original,
                                  stored: stored, isDirectory: file.isDirectory, date: date)
            }
            let moves = try await client.prepareTrashMoves(serial: serial, paths: entries.map {
                (name: $0.name, source: $0.original, destination: $0.stored)
            }, restoring: false)
            return RemoteMoveBatch(device: connection.deviceID, destination: root, moves: moves,
                                   trash: TrashBatch(action: .put, entries: entries))
        }
    }

    private func currentTrashSelection(_ entries: [TrashEntry]) -> Bool {
        let available = Dictionary(uniqueKeysWithValues: trashEntries.map { ($0.id, $0) })
        let reserved = Set(trashDeletionBatch?.items.filter { $0.state != .deleted }.map(\.id) ?? [])
        return !entries.isEmpty && Set(entries.map(\.id)).count == entries.count
            && entries.allSatisfy { $0 == available[$0.id] && !reserved.contains($0.id) }
    }

    func restoreTrash(_ entries: [TrashEntry]) {
        guard uploadTarget != nil, let connection = transfers.connection, currentTrashSelection(entries) else {
            error = L10n.text("回收站项目已变化，请重新选择。")
            return
        }
        guard canStartJournaledEdit(on: connection) else { return }
        runBatchMove(on: connection, label: TrashAction.restore.title, retry: false) { _ in
            let moves = try await connection.client.prepareTrashMoves(serial: connection.serial, paths: entries.map {
                (name: $0.name, source: $0.stored, destination: $0.original)
            }, restoring: true)
            return RemoteMoveBatch(device: connection.deviceID, destination: "", moves: moves,
                                   trash: TrashBatch(action: .restore, entries: entries))
        }
    }

    private func resolveRestoreDirectory(_ directory: String, in target: UploadTarget) async throws -> String {
        guard uploadTarget == target else { throw HubError.message(L10n.text("设备已变化，请重新选择回收站项目。")) }
        let client = ADBClient(executable: target.executable)
        let paths = try await client.canonicalPaths(serial: target.serial, paths: [directory])
        guard let canonical = paths[directory], !TrashEntry.isStorage(canonical) else {
            throw HubError.message(L10n.text("请选择回收站以外的目标目录。"))
        }
        return canonical
    }

    func trashRestoreDirectories(at directory: String, in target: UploadTarget) async throws -> [DeviceFile] {
        let canonical = try await resolveRestoreDirectory(directory, in: target)
        return try await moveDirectories(at: canonical, in: target)
    }

    func previewTrashRestore(_ entries: [TrashEntry], to directory: String, in target: UploadTarget) async throws
        -> [TrashRestoreRow] {
        guard let connection = transfers.connection, currentTrashSelection(entries) else {
            throw HubError.message(L10n.text("回收站项目已变化，请重新选择。"))
        }
        let canonical = try await resolveRestoreDirectory(directory, in: target)
        let preview = try await connection.client.previewTrashRestore(serial: connection.serial, items: entries.map {
            (name: $0.name, source: $0.stored)
        }, to: canonical)
        var rows = zip(entries, preview).map { TrashRestoreRow(entry: $0, preview: $1) }
        let protected = transfers.protectedRemotePaths(for: connection)
        if !protected.isEmpty {
            let paths = try await canonicalProtectedPaths(protected, connection: connection)
            for index in rows.indices {
                if let move = rows[index].preview.move, Self.overlapsProtectedMove(move, protected: paths) {
                    rows[index].preview.issues.append(L10n.text("涉及正在处理或已暂停的传输任务"))
                }
            }
        }
        try Task.checkCancellation()
        guard uploadTarget == target, currentTrashSelection(entries) else {
            throw HubError.message(L10n.text("设备或回收站项目已变化，请重新选择。"))
        }
        return rows
    }

    func startTrashRestore(_ rows: [TrashRestoreRow], in target: UploadTarget) {
        let entries = rows.map(\.entry)
        let moves = rows.compactMap(\.preview.move)
        guard uploadTarget == target, let connection = transfers.connection, currentTrashSelection(entries),
              rows.allSatisfy({ $0.preview.issues.isEmpty }), moves.count == entries.count,
              let first = moves.first else {
            error = L10n.text("设备、回收站项目或目标目录已变化，请重新预览。")
            return
        }
        guard canStartJournaledEdit(on: connection) else { return }
        let destination = (first.destination as NSString).deletingLastPathComponent
        runBatchMove(RemoteMoveBatch(device: connection.deviceID, destination: destination, moves: moves,
                                    trash: TrashBatch(action: .restoreToDirectory, entries: entries)),
                     on: connection, retry: false)
    }

    var trashDeletionBatch: TrashDeletionBatch? {
        guard let device = transfers.connection?.deviceID else { return nil }
        return moveSnapshot.deletions?.first { $0.device == device }
    }

    var canManageTrashDeletion: Bool { !busy && moveRecovery == nil && fileRecordWrite == nil && moveBatch?.checking != true }

    func prepareTrashClear(for device: TransferDeviceID) -> TrashClearRequest? {
        guard uploadTarget != nil, let connection = transfers.connection, connection.deviceID == device,
              let phone = selectedDevice, moveBatch?.isFinished != false, trashDeletionBatch?.isFinished != false else {
            return nil
        }
        let entries = trashEntries
        guard !entries.isEmpty else { return nil }
        return TrashClearRequest(device: device, phoneName: phone.model, entries: entries)
    }

    func clearTrash(_ request: TrashClearRequest) {
        guard transfers.connection?.deviceID == request.device else {
            error = L10n.text("请重新连接确认页中显示的手机。")
            return
        }
        startTrashDeletion(request.entries, isClear: true)
    }

    func permanentlyDeleteTrash(_ entries: [TrashEntry]) {
        startTrashDeletion(entries, isClear: false)
    }

    private func startTrashDeletion(_ entries: [TrashEntry], isClear: Bool) {
        guard uploadTarget != nil, let connection = transfers.connection, currentTrashSelection(entries),
              trashDeletionBatch?.isFinished != false else {
            error = L10n.text("回收站项目已变化，或仍有一批删除待处理。")
            return
        }
        guard canStartJournaledEdit(on: connection) else { return }
        let namespace = moveSnapshot.namespace
        runTrashDeletion(on: connection, action: isClear ? L10n.text("清空回收站") : L10n.text("永久删除")) { protected in
            try await self.checkTrashDeletionTransfers(entries, protected: protected, on: connection)
            var items: [TrashDeletionItem] = []
            for entry in entries {
                let remote = try await connection.client.prepareTrashDeletion(serial: connection.serial, path: entry.stored,
                    namespace: namespace, entryID: entry.id, isDirectory: entry.isDirectory)
                try Task.checkCancellation()
                items.append(TrashDeletionItem(entry: entry, remote: remote))
            }
            return TrashDeletionBatch(device: connection.deviceID, items: items, isClear: isClear)
        }
    }

    func retryTrashDeletion() {
        guard canManageTrashDeletion, let batch = trashDeletionBatch, !batch.isFinished,
              let connection = transfers.connection else { return }
        if batch.checkIndex != nil {
            reconcileTrashDeletion(on: connection)
            return
        }
        runTrashDeletion(on: connection, action: batch.action) { protected in
            var updated = batch
            do {
                try await self.checkTrashDeletionTransfers(batch.items.filter { $0.state != .deleted }.map(\.entry),
                                                          protected: protected, on: connection)
            } catch {
                try Task.checkCancellation()
                updated.blockingMessage = L10n.diagnostic(error.localizedDescription)
                try await self.storeTrashDeletion(updated)
                self.status = L10n.text("{1} · {2}", batch.action, L10n.text("已暂停"))
                return nil
            }
            updated.blockingMessage = nil
            return updated
        }
    }

    func endTrashDeletion() {
        guard canManageTrashDeletion, let batch = trashDeletionBatch, batch.checkIndex == nil else { return }
        var snapshot = moveSnapshot
        snapshot.deletions?.removeAll { $0.device == batch.device }
        let updated = snapshot
        perform(L10n.text("更新文件操作记录"), reportsCompletion: false) {
            try await self.saveMoveSnapshot(updated)
        }
    }

    private func checkTrashDeletionTransfers(_ entries: [TrashEntry], protected: [String],
                                             on connection: TransferConnection) async throws {
        guard !protected.isEmpty else { return }
        let paths = try await canonicalProtectedPaths(protected, connection: connection).map { $0.lowercased() }
        for entry in entries {
            let related = [entry.stored.lowercased(), entry.original.lowercased()]
            if paths.contains(where: { path in related.contains { Self.remotePathsOverlap(path, $0) } }) {
                throw HubError.message(L10n.text("「{1}」涉及正在处理或已暂停的传输任务。", entry.name))
            }
        }
    }

    private func runTrashDeletion(on connection: TransferConnection, action: String,
                                  prepare: @escaping ([String]) async throws -> TrashDeletionBatch?) {
        let session = generation
        perform(action, reportsCompletion: false) {
            try await self.transfers.withRemotePathEdit(on: connection) { protected in
                guard var batch = try await prepare(protected) else { return }
                try Task.checkCancellation()
                try await self.storeTrashDeletion(batch)
                for index in batch.items.indices where batch.items[index].state != .deleted {
                    try Task.checkCancellation()
                    let item = batch.items[index]
                    self.status = "\(action) \(index + 1)/\(batch.items.count) · \(item.entry.name)"
                    batch.items[index].state = .checking
                    try await self.storeTrashDeletion(batch)
                    try Task.checkCancellation()
                    let outcome: TrashDeleteState
                    do {
                        let confirmed = try await connection.client.reconcileTrashDeletion(serial: connection.serial, item: item.remote)
                        try Task.checkCancellation()
                        if confirmed == .present || confirmed == .partial {
                            outcome = try await connection.client.applyTrashDeletion(serial: connection.serial, item: item.remote)
                        } else {
                            outcome = confirmed
                        }
                        try Task.checkCancellation()
                    } catch {
                        if self.generation == session, self.transfers.connection == connection {
                            self.reconcileTrashDeletion(on: connection)
                        }
                        return
                    }
                    batch.items[index].state = outcome
                    try await self.storeTrashDeletion(batch)
                    if outcome != .deleted { break }
                }
                self.status = L10n.text("{1} · {2}", action, (batch.isFinished ? L10n.text("完成") : L10n.text("已暂停")))
            }
        }
    }

    private func storeTrashDeletion(_ batch: TrashDeletionBatch) async throws {
        var snapshot = moveSnapshot
        var batches = snapshot.deletions ?? []
        batches.removeAll { $0.device == batch.device }
        batches.append(batch)
        snapshot.deletions = batches
        let deleted = Set(batch.items.filter { $0.state == .deleted }.map(\.id))
        let partial = Set(batch.items.filter { $0.state == .partial }.map(\.id))
        snapshot.trash.removeAll { $0.device == batch.device && deleted.contains($0.id) }
        for index in snapshot.trash.indices where snapshot.trash[index].device == batch.device
            && partial.contains(snapshot.trash[index].id) {
            snapshot.trash[index].partiallyDeleted = true
        }
        try await saveMoveSnapshot(snapshot)
    }

    private func reconcileTrashDeletion(on connection: TransferConnection) {
        guard moveRecovery == nil, var batch = trashDeletionBatch, let index = batch.checkIndex else { return }
        transfers.beginPendingMoveCheck(on: connection)
        let session = generation
        let priorWork = work
        let draining = drainingRemoteEdit
        drainingRemoteEdit = nil
        moveRecovery = Task {
            await draining?.value
            await priorWork?.value
            defer {
                if self.generation == session {
                    self.moveRecovery = nil
                    self.transfers.finishPendingMoveCheck(on: connection)
                    self.objectWillChange.send()
                }
            }
            guard !Task.isCancelled, self.transfers.connection == connection else { return }
            do {
                try await self.transfers.withRemotePathEdit(on: connection) { _ in
                    let result = try await connection.client.reconcileTrashDeletion(serial: connection.serial,
                                                                                    item: batch.items[index].remote)
                    try Task.checkCancellation()
                    batch.items[index].state = result
                    try await self.storeTrashDeletion(batch)
                }
            } catch {
                if !Task.isCancelled, self.generation == session {
                    self.error = L10n.text("暂时无法核对永久删除结果。请连接原手机后重试核对。")
                }
            }
        }
        objectWillChange.send()
    }

    private func runBatchMove(_ batch: RemoteMoveBatch, on connection: TransferConnection, retry: Bool) {
        runBatchMove(on: connection, label: batch.trash?.action.title ?? L10n.text("批量移动"), retry: retry) { _ in batch }
    }

    private func runBatchMove(on connection: TransferConnection, label: String, retry: Bool,
                              prepare: @escaping ([String]) async throws -> RemoteMoveBatch) {
        guard !busy else { return }
        cancelDirectoryLoad()
        invalidateDirectoryCache()
        uploadedDirectoryRefresh?.cancel()
        let session = generation
        perform(label, reportsCompletion: false) {
            try await self.transfers.withRemotePathEdit(on: connection) { protected in
                var updated = try await prepare(protected)
                do {
                    let remaining = Array(updated.moves.dropFirst(updated.completed))
                    try await connection.client.validateBatchMoves(serial: connection.serial, moves: remaining,
                                                                   restore: updated.trash?.action.restoreLocation)
                    let reserved = updated.trash == nil ? protected + self.trashStoragePaths(for: connection) : protected
                    if !reserved.isEmpty {
                        let canonical = try await self.canonicalProtectedPaths(reserved, connection: connection)
                        if let blocked = remaining.first(where: { Self.overlapsProtectedMove($0, protected: canonical) }) {
                            throw HubError.message(L10n.text("「{1}」涉及回收站、正在处理或已暂停的传输任务。", blocked.name))
                        }
                    }
                } catch {
                    try Task.checkCancellation()
                    if retry {
                        self.status = L10n.text("{1} · {2}", label, L10n.text("等待重试"))
                        updated.detail = L10n.diagnostic(error.localizedDescription)
                        try await self.storeMoveBatch(updated)
                        return
                    }
                    throw error
                }
                try Task.checkCancellation()
                updated.detail = nil
                updated.failedAt = nil
                try await self.storeMoveBatch(updated)
                while let move = updated.current {
                    try Task.checkCancellation()
                    self.status = "\(label) \(updated.completed + 1)/\(updated.moves.count) · \(move.name)"
                    updated.checking = true
                    try await self.storeMoveBatch(updated)
                    try Task.checkCancellation()
                    do {
                        try await connection.client.applyMove(serial: connection.serial, move: move)
                        try Task.checkCancellation()
                    } catch let rejection as RemoteMoveRejection {
                        updated.checking = false
                        updated.detail = updated.trash?.action.restoreLocation != nil
                            ? L10n.text("「{1}」{2}文件保留在回收站。", move.name, L10n.diagnostic(rejection.localizedDescription))
                            : L10n.text("「{1}」{2}", move.name, L10n.diagnostic(rejection.localizedDescription))
                        updated.failedAt = updated.completed
                        try await self.storeMoveBatch(updated)
                        break
                    } catch {
                        if self.generation == session, self.transfers.connection == connection {
                            self.status = L10n.text("正在核对{1}", label)
                            self.recoverBatchMove(on: connection)
                        }
                        return
                    }
                    updated.completed += 1
                    updated.checking = false
                    try await self.storeMoveBatch(updated)
                }
                self.status = L10n.text("{1} · {2}", label, (updated.isFinished ? L10n.text("完成") : L10n.text("等待重试")))
                await self.refreshBatchMoveDirectory(on: connection, session: session)
            }
        }
    }

    private func saveMoveSnapshot(_ snapshot: RemoteMoveSnapshot) async throws {
        let store = moveBatchStore
        try await saveFileRecord(L10n.text("无法保存文件操作记录。请检查 Mac 上的磁盘空间和写入权限。"),
                                 write: { try store.save(snapshot) }) {
            self.moveSnapshot = snapshot
        }
    }

    private func saveFileRecord(_ message: String, write: @escaping @Sendable () throws -> Void,
                                publish: @escaping @MainActor () -> Void) async throws {
        try Task.checkCancellation()
        guard fileRecordWrite == nil else {
            throw HubError.message(L10n.text("正在保存文件操作记录，请稍后重试。"))
        }
        let task = Task {
            defer { fileRecordWrite = nil }
            do { try await RemoteFileRecordWriter.save(write) }
            catch { throw HubError.message(message) }
            publish()
        }
        fileRecordWrite = task
        try await task.value
    }

    private func storeMoveBatch(_ batch: RemoteMoveBatch) async throws {
        var snapshot = moveSnapshot
        let previous = snapshot.batches.first { $0.device == batch.device }
        if let trash = batch.trash, let previous, batch.completed > previous.completed {
            // Progress and the recovery index commit together. A crash cannot persist one without the other.
            let completed = trash.entries[previous.completed..<batch.completed]
            let ids = Set(completed.map(\.id))
            snapshot.trash.removeAll { ids.contains($0.id) }
            if trash.action == .put { snapshot.trash.append(contentsOf: completed) }
        }
        snapshot.batches.removeAll { $0.device == batch.device }
        snapshot.batches.append(batch)
        try await saveMoveSnapshot(snapshot)
    }

    private func trashStoragePaths(for connection: TransferConnection) -> [String] {
        Array(Set(moveSnapshot.trash.filter { $0.device == connection.deviceID }
            .map { ($0.stored as NSString).deletingLastPathComponent }))
    }

    private func recoverBatchMove(on connection: TransferConnection) {
        guard moveRecovery == nil, let batch = moveBatch, batch.checking, let move = batch.current else { return }
        transfers.beginPendingMoveCheck(on: connection)
        let label = batch.trash?.action.title ?? L10n.text("批量移动")
        let session = generation
        let priorWork = work
        let draining = drainingRemoteEdit
        drainingRemoteEdit = nil
        moveRecovery = Task {
            await draining?.value
            await priorWork?.value
            defer {
                if self.generation == session {
                    self.moveRecovery = nil
                    self.transfers.finishPendingMoveCheck(on: connection)
                    self.objectWillChange.send()
                }
            }
            guard !Task.isCancelled, self.transfers.connection == connection else { return }
            do {
                try await self.transfers.withRemotePathEdit(on: connection) { _ in
                    let result = try await connection.client.reconcileMove(serial: connection.serial, move: move)
                    try Task.checkCancellation()
                    var updated = batch
                    updated.unresolved = nil
                    switch result {
                    case .moved:
                        updated.completed += 1
                        updated.checking = false
                        updated.detail = nil
                    case .unchanged:
                        updated.checking = false
                        updated.detail = batch.trash?.action.restoreLocation == nil
                            ? L10n.text("已核对，项目仍在源目录。") : L10n.text("已核对，项目仍在回收站。")
                    case .uncertain:
                        updated.unresolved = true
                        updated.detail = L10n.text("无法确认这个项目的位置。请检查源目录和目标目录后再次核对。")
                    }
                    try await self.storeMoveBatch(updated)
                    self.status = L10n.text("{1} · {2}", label, (updated.isFinished ? L10n.text("完成") : (updated.checking ? L10n.text("待核对") : L10n.text("等待重试"))))
                    await self.refreshBatchMoveDirectory(on: connection, session: session)
                }
            } catch {
                if !Task.isCancelled, self.generation == session {
                    self.error = L10n.text("暂时无法核对「{1}」。请连接原手机后再次核对。{2}", label, L10n.diagnostic(error.localizedDescription))
                }
            }
        }
        objectWillChange.send()
    }

    private func refreshBatchMoveDirectory(on connection: TransferConnection, session: UUID) async {
        guard !Task.isCancelled, generation == session, transfers.connection == connection else { return }
        invalidateDirectoryCache()
        _ = try? await refreshCurrentDirectory(path, on: connection, session: session)
    }

    private func canonicalProtectedPaths(_ paths: [String], connection: TransferConnection) async throws -> [String] {
        let canonical = try await connection.client.canonicalPaths(serial: connection.serial, paths: paths)
        return paths.map { canonical[$0] ?? $0 }
    }

    private static func overlapsProtectedMove(_ move: RemoteMove, protected: [String]) -> Bool {
        // Shared storage may treat names differing only by letter case as the same entry.
        let source = move.source.lowercased()
        let destination = move.destination.lowercased()
        return protected.contains { path in
            let name = path.lowercased()
            return remotePathsOverlap(name, source) || remotePathsOverlap(name, destination)
        }
    }

    func batchRenameDirectory(in target: UploadTarget) async throws -> [DeviceFile] {
        guard uploadTarget == target else { throw HubError.message(L10n.text("设备或目录已变化，请重新打开批量重命名。")) }
        let entries = try await ADBClient(executable: target.executable).files(serial: target.serial, path: target.directory)
        try Task.checkCancellation()
        guard uploadTarget == target else { throw HubError.message(L10n.text("设备或目录已变化，请重新打开批量重命名。")) }
        return entries
    }

    func batchRename(_ selection: [DeviceFile], rule: BatchRenameRule, in target: UploadTarget,
                     didRename: @escaping ([DeviceFile]) -> Void) {
        guard uploadTarget == target, let connection = transfers.connection, selection.count > 1, rule.isReady else {
            error = L10n.text("设备、目录或所选项目已变化，请重新预览。")
            return
        }
        guard canStartJournaledEdit(on: connection) else { return }
        uploadedDirectoryRefresh?.cancel()
        invalidateDirectoryCache()
        perform(L10n.text("批量重命名")) {
            try await self.transfers.withRemotePathEdit(on: connection) { protected in
                let client = connection.client
                let current = try await client.files(serial: connection.serial, path: target.directory)
                let plan = BatchRenamePlan(selection: selection, directory: current, rule: rule)
                guard plan.canApply else {
                    if let row = plan.issues.first, let issue = row.issue {
                        throw HubError.message(L10n.text("「{1}」：{2}。请重新预览。", row.file.name, L10n.text(issue.rawValue)))
                    }
                    throw HubError.message(L10n.text("这批项目没有名称变化。"))
                }
                let moves = try await client.prepareBatchRenames(serial: connection.serial, parent: target.directory, plan: plan)
                try await self.checkRemoteEdit(affected: moves.flatMap { [$0.source, $0.destination] },
                                               protected: protected, connection: connection)
                var completed = 0
                do {
                    for move in moves {
                        try Task.checkCancellation()
                        guard self.generation == target.session, self.transfers.connection == connection,
                              self.path == target.directory else { throw CancellationError() }
                        self.status = L10n.text("批量重命名 {1}/{2}", completed, moves.count)
                        let progress = BatchRenameProgress(completed: completed, total: moves.count)
                        try await self.applyJournaledMove(move, on: connection, session: target.session, batch: progress)
                        completed += 1
                    }
                } catch {
                    _ = try? await self.refreshCurrentDirectory(target.directory, on: connection, session: target.session)
                    try Task.checkCancellation()
                    if self.pendingMoves.contains(where: { $0.device == connection.deviceID }) { throw error }
                    throw HubError.message(L10n.text("已重命名 {1}/{2} 项。{3}", completed, moves.count, L10n.diagnostic(error.localizedDescription)))
                }
                do {
                    guard let refreshed = try await self.refreshCurrentDirectory(
                        target.directory, on: connection, session: target.session
                    ) else { return }
                    let names = Set(plan.rows.map(\.name))
                    didRename(refreshed.filter { names.contains($0.name) })
                    self.batchRenameNotice = L10n.text("已重命名 {1} 项。", completed)
                } catch {
                    try Task.checkCancellation()
                    throw HubError.message(L10n.text("已重命名 {1} 项，但列表刷新失败。请手动刷新。", completed))
                }
            }
        }
    }

    private func canStartJournaledEdit(on connection: TransferConnection) -> Bool {
        guard moveBatchStoreReadable else {
            error = L10n.text("无法读取批量移动记录，请检查 Mac 上的应用数据。")
            return false
        }
        guard moveBatch?.isFinished != false, trashDeletionBatch?.checkIndex == nil else {
            error = L10n.text("这台手机还有未完成的文件操作。请先打开结果处理。")
            return false
        }
        guard moveJournalReadable else {
            error = L10n.text("无法读取上次文件操作的记录，请检查 Mac 上的应用数据。")
            return false
        }
        guard !pendingMoves.contains(where: { $0.device == connection.deviceID }) else {
            recoverRemoteMove(on: connection)
            return false
        }
        if case .session = connection.deviceID {
            error = L10n.text("无法确认手机身份。请重新连接或使用 USB，以便在断线后核对操作结果。")
            return false
        }
        return true
    }

    private func applyJournaledMove(_ move: RemoteMove, on connection: TransferConnection, session: UUID,
                                    batch: BatchRenameProgress? = nil) async throws {
        try await savePendingMoves(pendingMoves + [PendingRemoteMove(device: connection.deviceID, move: move, batch: batch)])
        do {
            try Task.checkCancellation()
            try await connection.client.applyMove(serial: connection.serial, move: move)
            try Task.checkCancellation()
        } catch let rejection as RemoteMoveRejection {
            try await removePendingMove(on: connection)
            throw rejection
        } catch {
            if generation == session, transfers.connection == connection { recoverRemoteMove(on: connection) }
            throw error
        }
        try await removePendingMove(on: connection)
    }

    private func savePendingMoves(_ updated: [PendingRemoteMove]) async throws {
        let journal = moveJournal
        try await saveFileRecord(L10n.text("无法保存移动记录。请检查 Mac 上的磁盘空间和写入权限。"),
                                 write: { try journal.save(updated) }) {
            self.pendingMoves = updated
        }
    }

    private func removePendingMove(on connection: TransferConnection) async throws {
        try await savePendingMoves(pendingMoves.filter { $0.device != connection.deviceID })
    }

    private func recoverRemoteMove(on connection: TransferConnection) {
        guard moveRecovery == nil, let pending = pendingMoves.first(where: { $0.device == connection.deviceID }) else { return }
        let session = generation
        let priorWork = work
        let draining = drainingRemoteEdit
        drainingRemoteEdit = nil
        moveRecovery = Task {
            await draining?.value
            await priorWork?.value
            defer {
                if self.generation == session {
                    self.moveRecovery = nil
                    self.transfers.finishPendingMoveCheck(on: connection)
                    self.objectWillChange.send()
                }
            }
            guard !Task.isCancelled, self.transfers.connection == connection else { return }
            do {
                try await self.transfers.withRemotePathEdit(on: connection) { _ in
                    let result = try await connection.client.reconcileMove(serial: connection.serial, move: pending.move)
                    try Task.checkCancellation()
                    guard self.generation == session, self.transfers.connection == connection else { return }
                    try await self.removePendingMove(on: connection)
                    self.error = nil
                    if let batch = pending.batch {
                        switch result {
                        case .moved:
                            self.batchRenameNotice = L10n.text("已确认重命名 {1}/{2} 项。", batch.completed + 1, batch.total)
                        case .unchanged:
                            self.batchRenameNotice = L10n.text("已重命名 {1}/{2} 项。「{3}」仍保留原名。", batch.completed, batch.total, pending.move.name)
                        case .uncertain:
                            self.batchRenameNotice = L10n.text("已确认重命名 {1}/{2} 项。请检查「{3}」的当前名称。", batch.completed, batch.total, pending.move.name)
                        }
                        return
                    }
                    switch result {
                    case .moved: self.moveNotice = L10n.text("已确认「{1}」移到了目标目录。", pending.move.name)
                    case .unchanged: self.moveNotice = L10n.text("「{1}」仍在源目录。可以重新发起移动。", pending.move.name)
                    case .uncertain: self.moveNotice = L10n.text("无法确认「{1}」的位置。请检查源目录和目标目录。", pending.move.name)
                    }
                }
            } catch {
                if !Task.isCancelled, self.generation == session {
                    if pending.batch == nil {
                        self.moveNotice = L10n.text("暂时无法核对上次移动。重新连接原手机后会再次检查。")
                    } else {
                        self.batchRenameNotice = L10n.text("暂时无法核对批量重命名。重新连接原手机后会再次检查。")
                    }
                }
            }
        }
    }

    private func checkRemoteEdit(affected: [String], protected: [String], connection: TransferConnection) async throws {
        let roots = trashStoragePaths(for: connection)
        guard !protected.isEmpty || !roots.isEmpty || affected.contains(where: TrashEntry.isStorage) else { return }
        let canonical = try await connection.client.canonicalPaths(serial: connection.serial, paths: protected + affected)
        let names = affected.map { (canonical[$0] ?? $0).lowercased() }
        if names.contains(where: { name in
            TrashEntry.isStorage(name) || roots.contains { Self.remotePathsOverlap($0.lowercased(), name) }
        }) {
            throw HubError.message(L10n.text("这个路径涉及回收站。请在「回收站」中管理这些项目。"))
        }
        if protected.contains(where: { path in
            let name = (canonical[path] ?? path).lowercased()
            return names.contains { Self.remotePathsOverlap(name, $0) }
        }) {
            throw HubError.message(L10n.text("这个路径有正在处理或已暂停的传输任务。请先完成或取消相关任务。"))
        }
    }

    private static func remotePathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs == "/" || rhs == "/" || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }

    func enqueueUploads() -> Bool {
        guard let target = uploadTarget else { return false }
        let panel = NSOpenPanel()
        panel.title = L10n.text("选择要上传的文件或文件夹")
        panel.prompt = L10n.text("加入队列")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return false }
        return enqueueUploads(panel.urls, to: target)
    }

    func enqueueUploads(_ urls: [URL], to target: UploadTarget) -> Bool {
        guard uploadTarget == target else {
            error = L10n.text("设备或目标文件夹已变化，请重新选择上传项目。")
            return false
        }
        guard !urls.isEmpty else {
            error = L10n.text("无法读取拖入的文件。")
            return false
        }
        let sources = urls.map { url in
            (url, try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory)
        }
        let existing = Dictionary(files.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let conflicts = Set(sources.compactMap { url, isDirectory in
            let name = url.lastPathComponent
            return isDirectory == false && existing[name]?.isDirectory == false ? name : nil
        })
        var replace = false
        if !conflicts.isEmpty {
            let alert = NSAlert()
            alert.messageText = L10n.text("目标目录已有 {1} 个同名文件", conflicts.count)
            alert.informativeText = L10n.text("可以跳过同名文件，或确认上传完成后替换。")
            alert.addButton(withTitle: L10n.text("跳过同名文件"))
            alert.addButton(withTitle: L10n.text("替换同名文件"))
            alert.addButton(withTitle: L10n.text("取消导入"))
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return false }
            replace = response == .alertSecondButtonReturn
        }
        guard uploadTarget == target, let connection = transfers.connection else { return false }
        let device = selectedDevice?.model ?? target.serial
        var reservedNames = Set(transfers.items.filter {
            $0.state.isInQueue && $0.isUpload && $0.deviceID == connection.deviceID && $0.location == target.directory
        }.map(\.name))
        let batch = sources.map { local, isDirectory in
            let name = local.lastPathComponent
            var item = QueuedTransfer(deviceID: connection.deviceID, device: device,
                                      operation: .upload(local: local, directory: target.directory,
                                                         isDirectory: isDirectory == true,
                                                         replaceExisting: replace && conflicts.contains(name)))
            if isDirectory == nil || !local.isFileURL {
                item.detail = L10n.text("无法读取这个项目")
            } else if reservedNames.contains(name) {
                item.detail = L10n.text("已有同名项目加入队列")
            } else if let previous = existing[name], previous.isDirectory || isDirectory == true {
                item.detail = L10n.text("目标位置已有同名项目，已跳过")
            } else if conflicts.contains(name) && !replace {
                item.detail = L10n.text("已跳过同名文件")
            }
            if item.detail != nil { item.state = .skipped }
            else { reservedNames.insert(name) }
            return item
        }
        transfers.enqueue(batch)
        return true
    }

    private func refreshUploadedDirectory(_ upload: QueuedTransfer, connection: TransferConnection) {
        guard transfers.connection == connection else { return }
        invalidateDirectoryCache()
        guard path == upload.location || isLoadingDirectory else { return }
        let session = generation
        uploadedDirectoryRefresh?.cancel()
        uploadedDirectoryRefresh = Task {
            await work?.value
            await directoryLoad?.value
            _ = try? await refreshCurrentDirectory(upload.location, on: connection, session: session)
        }
    }

    func enqueueDownloads(_ files: [DeviceFile], to localDirectory: URL? = nil) -> Bool {
        guard let connection = transfers.connection, onlineSerial == connection.serial,
              !busy, !isLoadingDirectory, !files.isEmpty else { return false }
        let session = generation
        let destinations: [URL]
        let choosesSingleFile = localDirectory == nil && files.count == 1 && files.first?.isDirectory == false
        if let localDirectory {
            guard localDirectory.isFileURL,
                  (try? localDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                error = L10n.text("Mac 上的目标文件夹已不可用，请重新选择。")
                return false
            }
            destinations = downloadDestinations(for: files, in: localDirectory)
        } else if choosesSingleFile, let file = files.first {
            let panel = NSSavePanel()
            panel.title = L10n.text("下载文件")
            panel.prompt = L10n.text("下载")
            panel.nameFieldStringValue = LocalFileDestination.safeName(file.name, fallback: L10n.text("文件"))
            guard panel.runModal() == .OK, let destination = panel.url else { return false }
            destinations = [destination]
        } else {
            let panel = NSOpenPanel()
            panel.title = L10n.text("选择下载文件夹")
            panel.prompt = L10n.text("下载到这里")
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let directory = panel.url else { return false }
            destinations = downloadDestinations(for: files, in: directory)
        }

        guard generation == session, transfers.connection == connection else { return false }
        if choosesSingleFile, let destination = destinations.first,
           transfers.reservedDownloadPaths.contains(LocalFileDestination.key(for: destination)) {
            error = L10n.text("该位置已有下载任务，请选择其他文件名。")
            return false
        }
        let device = selectedDevice?.model ?? connection.serial
        let batch = zip(files, destinations).map { file, destination in
            let replace = choosesSingleFile && FileManager.default.fileExists(atPath: destination.path)
            return QueuedTransfer(deviceID: connection.deviceID, device: device,
                                  operation: .download(file: file, destination: destination, replaceExisting: replace),
                                  total: file.isDirectory ? nil : file.size)
        }
        transfers.enqueue(batch)
        return true
    }

    private func downloadDestinations(for files: [DeviceFile], in directory: URL) -> [URL] {
        var reserved = transfers.reservedDownloadPaths
        return files.map { file in
            let name = LocalFileDestination.safeName(file.name, fallback: L10n.text("文件"))
            return LocalFileDestination.uniqueURL(named: name, in: directory, reserving: &reserved)
        }
    }

    func loadPhotosIfNeeded() {
        guard !Task.isCancelled, photoLibrary == nil else { return }
        reloadMedia()
    }

    func selectGalleryVideos(_ videos: Bool) {
        guard videos != showsVideos, !busy, !galleryLoading, photoLibrary != nil else { return }
        if gallery.selectCachedKind(videos: videos) {
            clearGalleryExportResult()
        } else {
            reloadMedia(videos: videos)
        }
    }

    private func clearGalleryExportResult() {
        photoExportResult = nil
        exportedPhotos = []
        previewExport = nil
    }

    private static func identifyGalleryUser(client: ADBClient, device: AndroidDevice) async -> Int? {
        let started = ContinuousClock.now
        let user = try? await client.currentApplicationUser(device: device)
        if !Task.isCancelled {
            GalleryMetrics.record("android_user", since: started, wireless: device.isWireless)
        }
        return user
    }

    private func readGalleryManifest(_ key: GalleryManifestCache.Key, device: AndroidDevice) async -> [MediaItem]? {
        let started = ContinuousClock.now
        let items = await galleryCache.read(key)
        if !Task.isCancelled {
            GalleryMetrics.record(items == nil ? "manifest_cache_miss" : "manifest_cache_read",
                                  since: started, count: items?.count, wireless: device.isWireless)
        }
        return items
    }

    func reloadMedia(retaining selection: Set<String> = [], near day: Date? = nil,
                     query: String = "", calendar: Calendar = .current, videos: Bool? = nil) {
        guard let device = selectedDevice, device.isOnline, !galleryLoading else { return }
        let started = ContinuousClock.now
        let client = adb
        let session = generation
        let scanVideos = videos ?? showsVideos
        let startingAlbum = photoAlbumID
        let pendingIdentity = transferConnectionLookup
        galleryLoading = true
        galleryNotice = nil
        galleryLoad = Task {
            defer {
                if session == generation {
                    galleryLoading = false
                    galleryLoad = nil
                }
            }
            let initialUser = await pendingIdentity?.value
            guard !Task.isCancelled, session == generation else { return }
            let user: Int?
            if let initialUser { user = initialUser }
            else { user = await Self.identifyGalleryUser(client: client, device: device) }
            guard !Task.isCancelled, session == generation, onlineSerial == device.serial,
                  selectedDevice?.transportID == device.transportID else { return }
            GalleryMetrics.record("gallery_identity_ready", since: started, wireless: device.isWireless)

            if galleryUser != nil, user == nil {
                galleryNotice = L10n.text("无法确认手机当前用户，请重试。")
                return
            }
            if photoLibrary != nil, galleryUser != user { resetGallery() }
            let firstPageNeeded = gallery.revision == nil || scanVideos != showsVideos
            var manifestKey: GalleryManifestCache.Key?
            let thumbnailDevice: String?
            switch transfers.connection?.deviceID {
            case .hardware(let digest):
                thumbnailDevice = "hardware:" + digest
                manifestKey = user.flatMap { GalleryManifestCache.Key(device: digest, user: $0, videos: scanVideos) }
            case .usb(let serial): thumbnailDevice = "usb:" + serial
            default: thumbnailDevice = nil
            }
            let library = photoLibrary ?? ADBPhotoLibrary(adb: client, serial: device.serial, thumbnailCacheDevice: thumbnailDevice)
            var previous = firstPageNeeded ? nil : gallery.all
            do {
                if firstPageNeeded, let key = manifestKey, let cached = await readGalleryManifest(key, device: device),
                   let catalog = try await GalleryBrowsing.prepare(cached) {
                    try Task.checkCancellation()
                    publishGallery(catalog, library: library, user: user, videos: scanVideos, calendar: calendar)
                    previous = cached
                    GalleryMetrics.record("cache_page_ready", since: started, count: cached.count, wireless: device.isWireless)
                }
                let items = try await (scanVideos ? library.videos(expectedUser: user) : library.photos(expectedUser: user))
                let catalog = try await GalleryBrowsing.prepare(items, comparing: previous)
                try Task.checkCancellation()
                if let catalog {
                    let sameAlbum = startingAlbum == photoAlbumID && query.isEmpty
                    publishGallery(catalog, library: library, user: user, videos: scanVideos, calendar: calendar,
                                   selection: sameAlbum ? selection : [], near: sameAlbum ? day : nil)
                    if previous == nil {
                        GalleryMetrics.record("live_page_ready", since: started, count: items.count, wireless: device.isWireless)
                    }
                }
                photoRefreshID = UUID()
                GalleryMetrics.record("verification_finished", since: started, count: items.count, wireless: device.isWireless)
                if catalog != nil, let key = manifestKey { await galleryCache.save(items, for: key) }
            } catch {
                guard !Task.isCancelled, session == generation else { return }
                if let user {
                    let actual = try? await client.currentApplicationUser(device: device)
                    guard !Task.isCancelled, session == generation else { return }
                    if let actual, actual != user { resetGallery() }
                }
                galleryNotice = L10n.diagnostic(error.localizedDescription)
            }
        }
    }

    private func publishGallery(_ catalog: PhotoAlbumCatalog, library: ADBPhotoLibrary, user: Int?, videos: Bool,
                                calendar: Calendar, selection: Set<String> = [], near day: Date? = nil) {
        if showsVideos != videos { clearGalleryExportResult() }
        gallery.reload(catalog, videos: videos, selection: selection, near: day, calendar: calendar)
        galleryUser = user
        if photoLibrary == nil { photoLibrary = library }
    }

    func selectPhotoAlbum(_ id: String?) {
        guard !busy, photoLibrary != nil else { return }
        gallery.selectAlbum(id)
    }

    func visibleMedia(in album: String?) -> [MediaItem] {
        gallery.visible(in: album)
    }

    func searchableMedia(in album: String?) -> [MediaItem] {
        gallery.searchable(in: album)
    }

    func loadMoreMedia() {
        gallery.loadMore()
    }

    func export(_ item: MediaItem, previewID: UUID? = nil) {
        exportPhotos([item], previewID: previewID)
    }

    func cancelPreviewExport(_ previewID: UUID) {
        guard previewExport?.owner == previewID, photoExportProgress != nil else { return }
        cancel()
    }

    func exportPhotos(_ items: [MediaItem], previewID: UUID? = nil) {
        guard let client = photoLibrary, !busy, let first = items.first else { return }
        let videos = first.isVideo
        let noun = videos ? L10n.text("视频") : L10n.text("照片")
        let summary = NSHostingView(rootView: PhotoExportSummary(count: items.count, bytes: items.reduce(0) { $0 + $1.bytes },
                                                               videos: videos))
        summary.frame.size = summary.fittingSize
        let destinations: [URL]
        if items.count == 1 {
            let panel = NSSavePanel(); panel.nameFieldStringValue = PhotoExport.filename(for: first)
            panel.title = L10n.text("导出{1}", noun); panel.prompt = L10n.text("导出"); panel.showsTagField = false
            panel.accessoryView = summary
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            destinations = [destination]
        } else {
            let panel = NSOpenPanel()
            panel.title = L10n.text("选择{1}导出文件夹", noun); panel.prompt = L10n.text("导出到这里")
            panel.accessoryView = summary
            panel.isAccessoryViewDisclosed = true
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let directory = panel.url else { return }
            destinations = PhotoExport.destinations(for: items, directory: directory)
        }
        guard !busy, photoLibrary?.cacheID == client.cacheID else { return }
        photoExportResult = nil; exportedPhotos = []
        previewExport = previewID.map { ($0, first.name) }
        perform(L10n.text("导出{1}", noun)) {
            try self.requirePhotoLibrary(client)
            self.photoExportProgress = PhotoExportProgress(completed: 0, total: items.count)
            defer { if self.photoLibrary?.cacheID == client.cacheID { self.photoExportProgress = nil } }
            do {
                try self.requirePhotoLibrary(client)
                for (index, item) in items.enumerated() {
                    try self.requirePhotoLibrary(client)
                    self.status = L10n.text("正在导出 {1}/{2}：{3}", index + 1, items.count, item.name)
                    try await client.export(item, destination: destinations[index], replaceExisting: items.count == 1)
                    try self.requirePhotoLibrary(client)
                    self.exportedPhotos.append(destinations[index])
                    self.photoExportProgress = PhotoExportProgress(completed: self.exportedPhotos.count, total: items.count)
                    self.photoExportResult = .saved(count: self.exportedPhotos.count, videos: videos)
                }
            } catch {
                if self.photoLibrary?.cacheID == client.cacheID {
                    self.photoExportResult = .interrupted(saved: self.exportedPhotos.count, total: items.count,
                                                          videos: videos, cancelled: Task.isCancelled)
                }
                throw error
            }
        }
    }

    func revealExportedPhotos() {
        guard !exportedPhotos.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(exportedPhotos)
    }

    func loadDeviceInfo(force: Bool = false) {
        guard !shuttingDown, deviceInfoTask == nil, let serial = onlineSerial else { return }
        if !force, !deviceInfoState.failed, let updatedAt = deviceInfoState.updatedAt,
           Date.now.timeIntervalSince(updatedAt) < 30 { return }
        let session = deviceSession
        let client = adb
        var state = deviceInfoState
        state.loading = true
        state.failed = false
        deviceInfoState = state
        deviceInfoTask = Task {
            let info = try? await client.deviceInfo(serial: serial)
            guard !Task.isCancelled, deviceSession == session, onlineSerial == serial else { return }
            deviceInfoTask = nil
            if let info {
                deviceInfoState = DeviceInfoState(info: info, updatedAt: .now)
            } else {
                state.loading = false
                state.failed = true
                deviceInfoState = state
            }
        }
    }

    func toggleMirroring() {
        if mirroring {
            mirroringState = .stopping
            mirrorTask?.cancel()
            return
        }
        guard !shuttingDown, let device = selectedDevice, device.isOnline else { return }
        guard FileManager.default.isExecutableFile(atPath: scrcpyPath) else {
            error = L10n.text("请在设置中指定 scrcpy 可执行文件。"); return
        }
        mirroringState = .starting
        let executable = scrcpyPath
        let client = adb
        let mainWindow = NSApp.keyWindow ?? NSApp.mainWindow
        var environment = ["ADB": client.executable]
        if executable == ADBClient.bundledTool("scrcpy"),
           let resources = Bundle.main.resourceURL?.appendingPathComponent("scrcpy") {
            environment["SCRCPY_SERVER_PATH"] = resources.appendingPathComponent("scrcpy-server").path
            environment["SCRCPY_ICON_DIR"] = resources.path
        }
        let current = generation
        mirrorTask = Task {
            defer {
                if current == generation { mirroringState = .idle; mirrorTask = nil }
            }
            do {
                let resolvedDisplay = try? await client.mirrorDisplay(serial: device.serial)
                try Task.checkCancellation()
                let name = resolvedDisplay?.name ?? deviceInfoState.info?.marketName ?? device.model
                var arguments = ["--serial", device.serial, "--window-title", L10n.text("{1} · 投屏", name),
                                 "--max-size", "1920", "--max-fps", "60", "--no-audio"]
                let size = resolvedDisplay?.size ?? CGSize(width: 1080, height: 2400)
                arguments += MirrorWindowPlacement.prepare(content: size, beside: mainWindow)
                let shouldReturnFocus = NSApp.isActive
                let (launches, launch) = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let readiness = Task {
                    for await pid in launches {
                        while !Task.isCancelled, generation == current, mirroringState == .starting {
                            if MirrorWindowPlacement.isVisible(processID: pid) {
                                if shouldReturnFocus {
                                    MirrorWindowPlacement.returnFocusIfNeeded(processID: pid, to: mainWindow)
                                }
                                mirroringState = .running(processID: pid)
                                return
                            }
                            try? await Task.sleep(for: .milliseconds(250))
                        }
                    }
                }
                defer {
                    launch.finish()
                    readiness.cancel()
                }
                _ = try await ProcessRunner.run(executable, arguments, timeout: 86400,
                                                environmentOverrides: environment, onLaunch: {
                    launch.yield($0)
                    launch.finish()
                })
            } catch {
                if !Task.isCancelled, current == generation { self.error = L10n.diagnostic(error.localizedDescription) }
            }
        }
    }

    func showMirrorWindow() {
        guard case .running(let pid) = mirroringState else { return }
        MirrorWindowPlacement.bringToFront(processID: pid)
    }

    func captureMirrorScreenshot() {
        guard !shuttingDown, mirrorWindowReady, screenshotTask == nil, let serial = onlineSerial else { return }
        let current = generation
        let client = adb
        capturingScreenshot = true
        screenshotTask = Task {
            defer {
                if generation == current { capturingScreenshot = false; screenshotTask = nil }
            }
            do {
                let pictures = try FileManager.default.url(for: .picturesDirectory, in: .userDomainMask,
                                                            appropriateFor: nil, create: true)
                let directory = pictures.appendingPathComponent("DroidHub Screenshots", isDirectory: true)
                let result = try await client.saveScreenshot(serial: serial, in: directory)
                guard !Task.isCancelled, generation == current else { return }
                screenshotURL = result
            } catch {
                if !Task.isCancelled, generation == current {
                    self.error = L10n.text("截图失败。{1}", L10n.diagnostic(error.localizedDescription))
                }
            }
        }
    }

    private func existingScreenshot() -> URL? {
        guard let screenshotURL else { return nil }
        guard FileManager.default.fileExists(atPath: screenshotURL.path) else {
            self.screenshotURL = nil
            error = L10n.text("这张截图已被移动或删除。")
            return nil
        }
        return screenshotURL
    }

    func openMirrorScreenshot() {
        guard let screenshot = existingScreenshot() else { return }
        if !NSWorkspace.shared.open(screenshot) { error = L10n.text("无法打开截图。") }
    }

    func copyMirrorScreenshot() -> Bool {
        guard let screenshot = existingScreenshot() else { return false }
        do {
            let image = try Data(contentsOf: screenshot, options: .mappedIfSafe)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if pasteboard.setData(image, forType: .png) { return true }
            error = L10n.text("无法将截图复制到剪贴板。")
        } catch {
            self.error = L10n.text("无法读取截图。{1}", L10n.diagnostic(error.localizedDescription))
        }
        return false
    }

    func revealMirrorScreenshot() {
        guard let screenshot = existingScreenshot() else { return }
        revealFileInFinder(screenshot, failureMessage: L10n.text("无法在 Finder 中显示截图"))
    }

    func revealFileInFinder(_ file: URL, failureMessage: String) {
        let workspace = NSWorkspace.shared
        guard let finder = workspace.urlForApplication(withBundleIdentifier: "com.apple.finder") else {
            error = L10n.text("无法找到 Finder。")
            return
        }
        let folder = file.deletingLastPathComponent()
        let current = generation
        Task {
            do {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                _ = try await workspace.open([folder], withApplicationAt: finder, configuration: configuration)
                workspace.activateFileViewerSelecting([file])
            } catch {
                if generation == current { self.error = L10n.text("{1}。{2}", failureMessage, L10n.diagnostic(error.localizedDescription)) }
            }
        }
    }

    func saveTools() {
        let defaults = UserDefaults.standard
        defaults.set(adbPath == ADBClient.bundledTool("adb") ? nil : adbPath, forKey: "adbPath")
        defaults.set(scrcpyPath == ADBClient.bundledTool("scrcpy") ? nil : scrcpyPath, forKey: "scrcpyPath")
    }
}
