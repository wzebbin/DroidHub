import SwiftUI
import AppKit
import DroidHubCore

private enum LibrarySection: String {
    case photos = "照片", files = "全部文件", apps = "应用管理", device = "设备"
    var symbol: String {
        switch self {
        case .photos: return "photo.on.rectangle"
        case .files: return "folder"
        case .apps: return "square.grid.2x2"
        case .device: return "iphone"
        }
    }
}

private final class FileListPresentation {
    struct Key: Equatable {
        let revision: UUID
        let query: String
        let showHidden: Bool
    }

    private var key: Key?
    private(set) var files: [DeviceFile] = []
    private(set) var ids: Set<String> = []

    func update(_ files: [DeviceFile], key: Key) {
        guard self.key != key else { return }
        self.key = key
        self.files = files.filter {
            !TrashEntry.isStorage($0.path) && (key.showHidden || !$0.name.hasPrefix(".")) &&
                (key.query.isEmpty || $0.name.localizedCaseInsensitiveContains(key.query))
        }
        ids = Set(self.files.map(\.id))
    }
}

struct WorkspaceView: View {
    @Environment(\.l10n) private var l10n
    @EnvironmentObject private var model: HubModel
    let startup: StartupMetrics
    @State private var section: LibrarySection = .device
    @State private var search = ""
    @State private var filePresentation = FileListPresentation()
    @State private var applicationQuery = ""
    @State private var showsSystemApplications = false
    @State private var showsDeviceDetails = false
    @State private var photoQueries: [Bool: [String?: String]] = [:]
    @State private var allSearchResults: GallerySearchResults?
    @State private var albumSearchResults: GallerySearchResults?
    @State private var selectedFiles = Set<String>()
    @State private var selectedPhotos = Set<String>()
    @State private var photoPreview: PhotoPreviewContext?
    @State private var connectionEntry: DeviceConnectionEntry?
    @State private var showTransferQueue = false
    @State private var fileNameRequest: FileNameRequest?
    @State private var moveRequest: MoveDirectoryRequest?
    @State private var moveResultRequest: BatchMoveResultRequest?
    @State private var trashMoveRequest: TrashMoveRequest?
    @State private var trashBrowserRequest: BatchMoveResultRequest?
    @State private var trashDeletionResultRequest: BatchMoveResultRequest?
    @State private var batchRenameRequest: BatchRenameRequest?
    @AppStorage("fileGridView") private var gridView = true
    @AppStorage("dualPaneFiles") private var dualPaneFiles = false
    @AppStorage("showHiddenFiles") private var showHidden = false
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false
    @State private var localDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser
    @FocusState private var searchFocused: Bool
    private let compactSidebarWidth: CGFloat = 60
    private let expandedSidebarWidth: CGFloat = 172
    private let headerControlHeight: CGFloat = 23

    private var photoQuery: String { photoQueries[model.showsVideos, default: [:]][model.photoAlbumID] ?? "" }
    private var photoSearch: Binding<String> {
        Binding(get: { photoQuery }, set: { photoQueries[model.showsVideos, default: [:]][model.photoAlbumID] = $0 })
    }

    private func gallerySearchKey(query: String, album: String?) -> GallerySearchKey? {
        guard section == .photos, !query.isEmpty, let revision = model.galleryRevision else { return nil }
        return GallerySearchKey(session: model.deviceSession, videos: model.showsVideos, album: album,
                                query: query, revision: revision)
    }

    private func searchResults(for key: GallerySearchKey) -> GallerySearchResults? {
        let results = key.album == nil ? allSearchResults : albumSearchResults
        guard let results, results.key.hasSameScope(as: key) else { return nil }
        return results
    }

    private func runGallerySearch(_ key: GallerySearchKey) async {
        guard searchResults(for: key)?.key != key else { return }
        let start = ContinuousClock.now
        do {
            if searchResults(for: key) == nil { try await Task.sleep(for: .milliseconds(150)) }
            let matches = try await GallerySearchResults.find(key.query, in: model.searchableMedia(in: key.album))
            try Task.checkCancellation()
            guard key == gallerySearchKey(query: photoQuery, album: model.photoAlbumID) else { return }
            let results = GallerySearchResults(key: key, matches: matches,
                limit: searchResults(for: key)?.limit ?? GalleryBrowsing.pageSize)
            if key.album == nil { allSearchResults = results }
            else { albumSearchResults = results }
            GalleryMetrics.record("search_page_ready", since: start, count: matches.count,
                                  wireless: model.selectedDevice?.isWireless == true)
        } catch is CancellationError {
            return
        } catch {
            assertionFailure("Unexpected gallery search error: \(error)")
        }
    }

    private func loadMoreGalleryMedia() {
        if let key = gallerySearchKey(query: photoQuery, album: model.photoAlbumID) {
            guard let results = searchResults(for: key), results.key == key, results.hasMore else { return }
            if key.album == nil { allSearchResults?.limit += GalleryBrowsing.pageSize }
            else { albumSearchResults?.limit += GalleryBrowsing.pageSize }
        } else {
            model.loadMoreMedia()
        }
    }

    private func deviceMenuTitle(_ device: AndroidDevice) -> String {
        let transport = device.isWireless ? "Wi-Fi" : "USB"
        let hasDuplicate = model.devices.contains {
            $0.serial != device.serial && $0.model == device.model && $0.isWireless == device.isWireless
        }
        var parts = [device.model, transport]
        if hasDuplicate { parts.append(device.serial) }
        if !device.isOnline { parts.append(device.statusLabel) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        if section == .files {
            filePresentation.update(model.files, key: .init(revision: model.fileListRevision, query: search, showHidden: showHidden))
        }
        let files = section == .files ? filePresentation.files : []
        let fileIDs = section == .files ? filePresentation.ids : []
        let selection = selectedFiles.isEmpty ? [] : files.filter { selectedFiles.contains($0.id) }
        let searchKey = gallerySearchKey(query: photoQuery, album: model.photoAlbumID)
        let photos = section == .photos ? displayedMedia(query: photoQuery, album: model.photoAlbumID) : []
        let photoIDs = Set(photos.map(\.id))
        return HStack(spacing: 0) {
            sidebar.frame(width: sidebarCollapsed ? compactSidebarWidth : expandedSidebarWidth)
            Rectangle().fill(HubStyle.line).frame(width: 1)
            VStack(spacing: 0) {
                if section == .files {
                    PhoneFolderNavigation(itemCount: files.count)
                    HStack(spacing: 10) {
                        fileTitleActions(downloads: selection, fileIDs: fileIDs)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, HubStyle.workspaceInset)
                    .frame(height: 40)
                    Divider().overlay(HubStyle.line)
                }
                content(files: files, photos: photos, photoIDs: photoIDs)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showTransferQueue {
                    Divider().overlay(HubStyle.line)
                    TransferQueuePanel(queue: model.transfers) { showTransferQueue = false }
                }
                if section != .device || model.busy {
                    footer(selection: selection)
                        .frame(height: 28)
                }
            }
            .background(HubStyle.canvas)
        }
        .background(HubStyle.sidebar)
        .foregroundStyle(HubStyle.ink)
        .tint(HubStyle.accent)
        .navigationTitle(l10n.text(section.rawValue))
        .toolbar { windowToolbar() }
        .disabled(photoPreview != nil)
        .accessibilityHidden(photoPreview != nil)
        .overlay {
            if let context = photoPreview {
                PhotoPreviewView(context: context) { photoPreview = nil }
                    .id(context.id)
            }
        }
        .task(id: section == .photos && model.online ? model.deviceSession : nil) {
            if section == .photos, model.online { model.loadPhotosIfNeeded() }
        }
        .task(id: searchKey) {
            if let searchKey { await runGallerySearch(searchKey) }
        }
        .task(id: model.adbPath) { await model.pollDevices() }
        .task(id: model.adbPath) { await model.watchDevices() }
        .onAppear { showTransferQueue = model.transfers.showsRestoredItems || model.transfers.storageIssue != nil }
        .onChange(of: model.path) { _ in selectedFiles.removeAll(); search = "" }
        .onChange(of: model.selectedSerial) { _ in selectedFiles.removeAll(); selectedPhotos = []; photoPreview = nil; search = "" }
        .onChange(of: model.deviceSession) { _ in showsDeviceDetails = false }
        .onChange(of: photoQuery) { _ in selectedPhotos = [] }
        .onChange(of: model.showsVideos) { _ in selectedPhotos = []; photoPreview = nil }
        .onChange(of: model.photoAlbumID) { _ in selectedPhotos = []; photoPreview = nil }
        .onChange(of: fileIDs) { ids in
            if section == .files { selectedFiles.formIntersection(ids) }
        }
        .onChange(of: firstPageReady) { ready in
            if ready { startup.record("first_page_ready") }
        }
        .onChange(of: photoIDs) { ids in
            if section == .photos { selectedPhotos.formIntersection(ids) }
        }
        .onChange(of: model.photoLibrary?.cacheID) { _ in
            selectedPhotos = []; photoPreview = nil; photoQueries = [:]
            allSearchResults = nil; albumSearchResults = nil
        }
        .sheet(item: $connectionEntry) { entry in DeviceConnectionSheet(entry: entry).environmentObject(model) }
        .sheet(item: $fileNameRequest) { request in
            FileNameEditor(request: request) { name in
                fileNameRequest = nil
                model.editRemoteFile(request.file, name: name, in: request.target) { updated in
                    if !search.isEmpty && !updated.name.localizedCaseInsensitiveContains(search) { search = "" }
                    selectedFiles = [updated.id]
                }
            }
        }
        .sheet(item: $moveRequest, content: movePicker)
        .sheet(item: $moveResultRequest) { batch in
            BatchMoveResultView(device: batch.device).environmentObject(model)
        }
        .sheet(item: $trashMoveRequest) { request in
            TrashMoveConfirmation(request: request) {
                trashMoveRequest = nil
                model.moveToTrash(request.files, in: request.target)
            }
        }
        .sheet(item: $trashBrowserRequest) { request in
            TrashBrowser(device: request.device, submit: { selected in
                trashBrowserRequest = nil
                model.restoreTrash(selected)
            }, submitChosen: { rows, target in
                trashBrowserRequest = nil
                model.startTrashRestore(rows, in: target)
            }, submitDeletion: { entries in
                trashBrowserRequest = nil
                model.permanentlyDeleteTrash(entries)
            }, submitClear: { request in
                trashBrowserRequest = nil
                model.clearTrash(request)
            })
            .environmentObject(model)
        }
        .sheet(item: $trashDeletionResultRequest) { request in
            TrashDeletionResultView(device: request.device).environmentObject(model)
        }
        .sheet(item: $batchRenameRequest) { request in
            BatchRenameEditor(request: request, readDirectory: { try await model.batchRenameDirectory(in: request.target) }) { rule in
                batchRenameRequest = nil
                model.batchRename(request.files, rule: rule, in: request.target) { renamed in
                    if !search.isEmpty && renamed.contains(where: { !$0.name.localizedCaseInsensitiveContains(search) }) {
                        search = ""
                    }
                    selectedFiles = Set(renamed.map(\.id))
                }
            }
        }
        .alert(noticeTitle,
               isPresented: Binding(get: { model.batchRenameNotice != nil || model.moveNotice != nil || model.error != nil },
                                    set: { if !$0 { clearNotice() } })) {
            Button(l10n.text("好"), role: .cancel) {}
        } message: { Text(l10n.diagnostic(model.batchRenameNotice ?? model.moveNotice ?? model.error ?? "")) }
    }

    private var firstPageReady: Bool {
        guard model.online else { return false }
        switch section {
        case .photos: return model.photoLibrary != nil
        case .files: return model.hasLoadedDirectory
        case .apps: return false
        case .device: return model.deviceInfoState.info != nil
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                navigation(.device)
                navigation(.files)
                navigation(.photos)
                navigation(.apps)
            }.padding(.horizontal, 9).padding(.top, 16)
            Spacer(minLength: 24)
            if sidebarCollapsed {
                Divider().overlay(HubStyle.line).padding(.horizontal, 15)
                VStack(spacing: 5) {
                    connectionButton
                    refreshDeviceButton
                    settingsButton
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                sidebarDeviceCard
                Divider().overlay(HubStyle.line).padding(.horizontal, 15)
                HStack {
                    settingsButton
                    connectionButton
                    Spacer()
                    refreshDeviceButton
                }.padding(.horizontal, 13).frame(height: 39)
            }
        }
    }

    private var connectionButton: some View {
        QuietIconButton(symbol: "cable.connector", help: l10n.text("连接设备")) { connectionEntry = .all }
            .disabled(model.busy)
    }

    private var refreshDeviceButton: some View {
        QuietIconButton(symbol: "arrow.clockwise", help: l10n.text("刷新设备")) {
            Task { await model.retryInitialDeviceDetection() }
        }
    }

    private var sidebarDeviceCard: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "iphone").font(.system(size: 21, weight: .regular)).foregroundStyle(HubStyle.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                if model.devices.count > 1 {
                    Picker(l10n.text("设备"), selection: $model.selectedSerial) {
                        ForEach(model.devices) { device in
                            Text(deviceMenuTitle(device)).tag(Optional(device.serial))
                        }
                    }.labelsHidden().controlSize(.small)
                } else {
                    let title = model.initialDeviceDetection == .checking ? "正在检测设备…" : "未连接手机"
                    Text(model.selectedDevice?.model ?? l10n.text(title)).font(.system(size: 11, weight: .medium)).lineLimit(1)
                }
                HStack(spacing: 5) {
                    Circle().fill(model.online ? HubStyle.green : HubStyle.muted).frame(width: 5, height: 5)
                    Text(sidebarDeviceStatus)
                        .font(.system(size: 10)).foregroundStyle(HubStyle.muted).lineLimit(2)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HubStyle.canvas.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 9).padding(.bottom, 9)
    }

    private var sidebarDeviceStatus: String {
        if let device = model.selectedDevice {
            if !device.isOnline { return device.statusLabel }
            return device.isWireless ? l10n.text("无线已连接") : l10n.text("USB 已连接")
        }
        switch model.initialDeviceDetection {
        case .checking: return "USB / Wi-Fi"
        case .failed: return l10n.text("无法检测设备")
        case .finished: return l10n.text("等待连接设备")
        }
    }

    private func navigation(_ item: LibrarySection) -> some View {
        Button {
            guard section != item else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                searchFocused = false
                section = item
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: item.symbol).font(.system(size: 14, weight: .regular))
                    .foregroundStyle(section == item ? HubStyle.accent : HubStyle.muted).frame(width: 20)
                if !sidebarCollapsed {
                    Text(l10n.text(item.rawValue)).font(.system(size: 12, weight: section == item ? .semibold : .regular))
                    Spacer()
                    if item == .photos && model.photoLibrary != nil {
                        Text("\(model.media.count)" + (model.hasMorePhotos ? "+" : ""))
                            .font(.system(size: 10)).monospacedDigit().foregroundStyle(HubStyle.muted)
                    }
                }
            }.foregroundStyle(HubStyle.ink)
                .padding(.horizontal, 10).frame(height: sidebarCollapsed ? 38 : 34)
                .background(section == item ? HubStyle.sidebarSelection : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(l10n.text(item.rawValue))
        .accessibilityLabel(l10n.text(item.rawValue))
        .accessibilityAddTraits(section == item ? .isSelected : [])
    }

    @ViewBuilder private var settingsButton: some View {
        if #available(macOS 14, *) {
            SettingsLink { Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 29, height: 25) }
                .buttonStyle(.plain).help(l10n.text("设置"))
        } else {
            QuietIconButton(symbol: "gearshape", help: l10n.text("设置")) { openToolSettings() }
        }
    }

    @ToolbarContentBuilder
    private func windowToolbar() -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 10) {
                Button {
                    sidebarCollapsed.toggle()
                } label: {
                    Label(sidebarCollapsed ? l10n.text("展开侧栏") : l10n.text("收起侧栏"), systemImage: "sidebar.left")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 15))
                        .foregroundStyle(HubStyle.ink)
                        .frame(width: 31, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(sidebarCollapsed ? l10n.text("展开侧栏") : l10n.text("收起侧栏"))
                Text(l10n.text(section.rawValue))
                    .font(.headline)
                    .fixedSize()
                    .accessibilityAddTraits(.isHeader)
            }
            .disabled(photoPreview != nil)
        }

        if #available(macOS 26, *) {
            ToolbarSpacer(.flexible, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) {
            QuietIconButton(symbol: "list.bullet.rectangle", help: l10n.text("传输队列"),
                            selected: showTransferQueue, height: headerControlHeight) {
                showTransferQueue.toggle()
            }
            .disabled(photoPreview != nil)
        }
    }

    @ViewBuilder
    private func fileTitleActions(downloads: [DeviceFile], fileIDs: Set<String>) -> some View {
        let canDownload = !model.busy && model.online && !model.isLoadingDirectory &&
            !downloads.isEmpty && model.transfers.connection != nil
        LibrarySearchField(placeholder: l10n.text("搜索当前文件夹"), query: $search, focus: $searchFocused,
                           width: 166, height: 27)
        Menu {
            Picker(l10n.text("排列方式"), selection: $gridView) {
                Label(l10n.text("图标视图"), systemImage: "square.grid.2x2").tag(true)
                Label(l10n.text("列表视图"), systemImage: "list.bullet").tag(false)
            }
            Divider()
            Toggle(l10n.text("Mac 双栏"), isOn: $dualPaneFiles).disabled(!model.online)
            Toggle(l10n.text("显示隐藏文件"), isOn: $showHidden)
        } label: {
            Label(l10n.text("视图"), systemImage: gridView ? "square.grid.2x2" : "list.bullet")
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton).fixedSize().help(l10n.text("切换文件视图"))

        ToolbarAction(title: l10n.text("导入"), symbol: "square.and.arrow.down", height: 27) {
            if model.enqueueUploads() { showTransferQueue = true }
        }
        .disabled(model.uploadTarget == nil)
        .keyboardShortcut("i", modifiers: .command)

        Menu {
            Button(l10n.text("新建文件夹…")) { editFileName() }
                .disabled(model.uploadTarget == nil)
            Button(downloads.isEmpty ? l10n.text("下载") : l10n.text("下载 {1} 项", downloads.count)) {
                enqueueDownloads(downloads)
            }
            .disabled(!canDownload).keyboardShortcut("e", modifiers: .command)
            Divider()
            Button(l10n.text("全选当前文件")) { selectedFiles = fileIDs }
                .disabled(!model.online || searchFocused || fileIDs.isEmpty)
                .keyboardShortcut(moveRequest == nil && moveResultRequest == nil ? KeyboardShortcut("a", modifiers: .command) : nil)
            Button(l10n.text("批量重命名…")) { openBatchRename(downloads) }
                .disabled(downloads.count < 2 || model.uploadTarget == nil)
            Button(l10n.text("移动到…")) { openMove(downloads) }
                .disabled(downloads.isEmpty || model.uploadTarget == nil)
            Button(l10n.text("移入回收站…")) { openTrashMove(downloads) }
                .disabled(downloads.isEmpty || model.uploadTarget == nil)
            Divider()
            Button(l10n.text("打开回收站")) {
                if let device = model.transfers.connection?.deviceID {
                    trashBrowserRequest = BatchMoveResultRequest(device: device)
                }
            }
            .disabled(model.transfers.connection == nil)
        } label: {
            Image(systemName: "ellipsis.circle").foregroundStyle(HubStyle.muted)
        }
        .menuStyle(.borderlessButton).fixedSize().help(l10n.text("更多文件操作")).accessibilityLabel(l10n.text("更多文件操作"))
    }

    @ViewBuilder
    private func photoActions(photos: [MediaItem], selection: [MediaItem]) -> some View {
        let photo = selection.count == 1 ? selection.first : nil
        let canExport = !model.busy && model.online && !selection.isEmpty && model.photoLibrary != nil
        QuietIconButton(symbol: model.showsVideos ? "play" : "eye",
                        help: model.showsVideos ? l10n.text("播放选中的视频") : l10n.text("预览选中的照片")) {
            if let photo { openPreview(photo, in: photos) }
        }
        .disabled(photo == nil)
        ToolbarAction(title: selection.count > 1 ? l10n.text("导出 {1} {2}", selection.count, model.galleryUnit) : l10n.text("导出"),
                      symbol: "square.and.arrow.up", prominent: canExport) {
            model.exportPhotos(selection)
        }
        .disabled(!canExport).keyboardShortcut("e", modifiers: .command)
        if model.online {
            HStack(spacing: 5) {
                Circle().fill(HubStyle.green).frame(width: 5, height: 5)
                    .accessibilityHidden(true)
                Text(model.photoLibrary == nil ? l10n.text("设备已连接") : l10n.text("图库已连接"))
                    .font(.system(size: 11)).foregroundStyle(HubStyle.ink)
            }
            .padding(.horizontal, 6)
            .fixedSize()
        } else {
            QuietIconButton(symbol: "link", help: l10n.text("连接设备")) { connectionEntry = .all }
                .disabled(model.busy)
        }
    }

    private func displayedMedia(query: String, album: String?) -> [MediaItem] {
        if query.isEmpty { return model.visibleMedia(in: album) }
        guard let key = gallerySearchKey(query: query, album: album) else { return [] }
        return searchResults(for: key)?.visible ?? []
    }

    @ViewBuilder private func content(files: [DeviceFile], photos: [MediaItem], photoIDs: Set<String>) -> some View {
        switch section {
        case .files:
            if dualPaneFiles, model.online {
                HSplitView {
                    LocalFilePane(directory: $localDirectory, queue: model.transfers,
                                  uploadTarget: model.uploadTarget, upload: enqueueUploads)
                        .frame(minWidth: 245, idealWidth: 325, maxWidth: .infinity, maxHeight: .infinity)
                    phoneFiles(files).frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                phoneFiles(files)
            }
        case .photos:
            let allQuery = photoQueries[model.showsVideos]?[nil] ?? ""
            let allItems = model.photoAlbumID == nil ? photos : displayedMedia(query: allQuery, album: nil)
            let key = gallerySearchKey(query: photoQuery, album: model.photoAlbumID)
            let results = key.flatMap { searchResults(for: $0) }
            let allKey = gallerySearchKey(query: allQuery, album: nil)
            let hasMoreAll = allKey.flatMap { searchResults(for: $0)?.hasMore } ?? (allKey == nil && model.hasMoreAllPhotos)
            PhotoLibraryView(items: photos, allItems: allItems, resultIDs: photoIDs,
                             selection: $selectedPhotos, query: photoSearch, allQuery: allQuery,
                             searchPending: key != nil && results?.key != key,
                             hasMore: key == nil ? model.hasMorePhotos : results?.key == key && results?.hasMore == true,
                             hasMoreAll: hasMoreAll,
                             loadNextPage: loadMoreGalleryMedia,
                             connect: { connectionEntry = .all }, preview: { openPreview($0, in: photos) }) {
                photoActions(photos: photos, selection: photos.filter { selectedPhotos.contains($0.id) })
            }
        case .apps:
            ApplicationLibraryView(connect: { connectionEntry = .all },
                                   onReady: { startup.record("first_page_ready") }, applications: model.applications,
                                   query: $applicationQuery,
                                   showsSystem: $showsSystemApplications)
        case .device:
            DeviceLibraryView(showsDetails: $showsDeviceDetails, connect: { connectionEntry = $0 })
                .id(model.deviceSession)
        }
    }

    private func phoneFiles(_ files: [DeviceFile]) -> some View {
        FileLibraryView(files: files, selection: $selectedFiles, gridView: gridView, searching: !search.isEmpty,
                        connect: { connectionEntry = .all }, download: enqueueDownloads,
                        rename: { editFileName($0) }, batchRename: openBatchRename, move: openMove,
                        trash: openTrashMove, upload: enqueueUploads)
    }

    private func footer(selection: [DeviceFile]) -> some View {
        HStack(spacing: 7) {
            if model.busy || (section == .files && model.isLoadingDirectory) {
                if let progress = model.photoExportProgress {
                    ProgressView(value: Double(progress.completed), total: Double(progress.total)).frame(width: 65)
                    Text(l10n.text("正在导出 {1}/{2} {3}{4}", progress.completed, progress.total, model.galleryUnit, model.galleryNoun)).lineLimit(1)
                } else {
                    ProgressView().controlSize(.mini)
                    Text(model.busy ? model.status : l10n.text("正在读取目录…")).lineLimit(1)
                }
                Button(l10n.text("取消")) { model.cancel() }.buttonStyle(.plain).foregroundStyle(HubStyle.accent)
            } else {
                if section == .files && model.online && !selection.isEmpty {
                    if selection.count == 1, let file = selection.first {
                        Text(file.name).lineLimit(1)
                    } else {
                        Text(l10n.text("已选择 {1} 个项目", selection.count))
                    }
                } else if section == .photos, let result = model.photoExportResult {
                    Text(result.message(l10n))
                    if !model.exportedPhotos.isEmpty {
                        Button(l10n.text("在 Finder 中显示")) { model.revealExportedPhotos() }.buttonStyle(.plain).foregroundStyle(HubStyle.accent)
                    }
                } else if section == .photos && model.photoLibrary != nil {
                    if photoQuery.isEmpty {
                        Text(l10n.text("已加载 {1} {2}{3}", model.media.count, model.galleryUnit, model.galleryNoun))
                    } else if let key = gallerySearchKey(query: photoQuery, album: model.photoAlbumID),
                              let results = searchResults(for: key), results.key == key {
                        Text(l10n.text("已显示 {1}/{2} {3}{4}", results.visibleCount, results.matches.count, model.galleryUnit, model.galleryNoun))
                    }
                    if !selectedPhotos.isEmpty { Text(l10n.text("· 已选择 {1} {2}", selectedPhotos.count, model.galleryUnit)) }
                } else if section == .apps {
                    ApplicationFooter(applications: model.applications, online: model.online,
                                      reveal: model.revealExportedApplication)
                } else if section != .files || !model.online {
                    Text(model.online ? l10n.text("设备已连接") : l10n.text("等待连接设备"))
                }
            }
            Spacer()
            if section == .files {
                if let batch = model.moveBatch {
                    Button("\(l10n.text(batch.trash == nil ? "移动结果" : "回收站操作结果")) · \(batch.completed)/\(batch.moves.count)") {
                        moveResultRequest = BatchMoveResultRequest(device: batch.device)
                    }
                    .buttonStyle(.plain).foregroundStyle(HubStyle.accent)
                }
                if let batch = model.trashDeletionBatch {
                    Button(l10n.text("删除结果 · {1}/{2}", batch.completed, batch.items.count)) {
                        trashDeletionResultRequest = BatchMoveResultRequest(device: batch.device)
                    }
                    .buttonStyle(.plain).foregroundStyle(HubStyle.accent)
                }
            }
            else if section == .photos && model.photoLibrary != nil { Text(l10n.text("手机存储")) }
        }.font(.system(size: 11)).foregroundStyle(HubStyle.muted).padding(.horizontal, HubStyle.workspaceInset)
    }

    private func enqueueDownloads(_ files: [DeviceFile]) {
        if model.enqueueDownloads(files, to: dualPaneFiles ? localDirectory : nil) { showTransferQueue = true }
    }

    private func enqueueUploads(_ urls: [URL], _ target: HubModel.UploadTarget) {
        if model.enqueueUploads(urls, to: target) { showTransferQueue = true }
    }

    private func clearNotice() {
        if model.batchRenameNotice != nil { model.batchRenameNotice = nil }
        else if model.moveNotice != nil { model.moveNotice = nil }
        else { model.error = nil }
    }

    private var noticeTitle: String {
        if model.batchRenameNotice != nil { return l10n.text("批量重命名结果") }
        return model.moveNotice == nil ? l10n.text("操作未完成") : l10n.text("移动结果")
    }

    private func movePicker(_ request: MoveDirectoryRequest) -> some View {
        let multiple = request.files.count > 1
        return MoveDirectoryPicker(title: l10n.text("移动到…"), initialDirectory: request.target.directory,
                                   source: request.target.directory,
                                   subtitle: multiple ? l10n.text("已选 {1} 项", request.files.count) : request.files.first?.name ?? "",
                                   previewButton: multiple ? l10n.text("预览移动") : l10n.text("移动到这里"), confirmButton: l10n.text("确认移动"),
                                   destinationIssue: { directory in
            if directory == request.target.directory { return l10n.text("请选择其他目标目录。") }
            if !multiple, let file = request.files.first, file.isDirectory,
               directory == file.path || directory.hasPrefix(file.path + "/") {
                return l10n.text("不能将文件夹移动到自身或子目录。")
            }
            return nil
        }, read: { try await model.moveDirectories(at: $0, in: request.target) },
           preview: multiple ? { try await model.previewBatchMove(request.files, to: $0, in: request.target) } : nil,
           canSubmit: { $0.issue == nil && $0.move != nil },
           rowContent: { row in
               moveStatusRow(row.file.name, status: row.issue ?? l10n.text("可移动"), isIssue: row.issue != nil)
           }) { destination, rows in
            moveRequest = nil
            if let rows {
                model.startBatchMove(rows, in: request.target)
            } else if let file = request.files.first {
                model.moveRemoteFile(file, to: destination, in: request.target)
            }
        }
    }

    private func openMove(_ files: [DeviceFile]) {
        guard let target = targetForMove(files) else { return }
        moveRequest = MoveDirectoryRequest(files: files, target: target)
    }

    private func openTrashMove(_ files: [DeviceFile]) {
        guard let target = targetForMove(files) else { return }
        trashMoveRequest = TrashMoveRequest(files: files, target: target)
    }

    private func targetForMove(_ files: [DeviceFile]) -> HubModel.UploadTarget? {
        guard !files.isEmpty, let target = model.uploadTarget else { return nil }
        if let batch = model.moveBatch, !batch.isFinished {
            moveResultRequest = BatchMoveResultRequest(device: batch.device)
            return nil
        }
        return target
    }

    private func openBatchRename(_ files: [DeviceFile]) {
        guard files.count > 1, let target = model.uploadTarget else { return }
        batchRenameRequest = BatchRenameRequest(files: files, target: target)
    }

    private func editFileName(_ file: DeviceFile? = nil) {
        guard let target = model.uploadTarget else { return }
        fileNameRequest = FileNameRequest(file: file, target: target)
    }

    private func openPreview(_ item: MediaItem, in items: [MediaItem]) {
        guard let client = model.photoLibrary, items.contains(where: { $0.id == item.id }) else { return }
        photoPreview = PhotoPreviewContext(items: items, initialID: item.id, client: client)
    }
}


private struct ApplicationFooter: View {
    @Environment(\.l10n) private var l10n
    @ObservedObject var applications: ApplicationLibraryState
    let online: Bool
    let reveal: (URL) -> Void

    var body: some View {
        Text(applications.applicationNotice ?? (online ? l10n.text("设备已连接") : l10n.text("等待连接设备")))
            .lineLimit(1)
        if let destination = applications.exportedPackageURL {
            Button(l10n.text("在 Finder 中显示")) { reveal(destination) }
                .buttonStyle(.plain).foregroundStyle(HubStyle.accent)
        }
    }
}
