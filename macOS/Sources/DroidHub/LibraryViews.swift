import SwiftUI
import AppKit
import DroidHubCore

struct PhoneFolderNavigation: View {
    @Environment(\.l10n) private var l10n
    @EnvironmentObject private var model: HubModel
    @State private var editingPath = false
    @State private var enteredPath = ""
    let itemCount: Int

    private struct DirectoryLevel: Identifiable {
        let name: String
        let path: String
        var id: String { path }
    }

    private var levels: [DirectoryLevel] {
        let components = model.path.split(separator: "/")
        let isPhoneStorage = components.first == "sdcard"
        var path = isPhoneStorage ? "/sdcard" : ""
        var levels = [DirectoryLevel(name: isPhoneStorage ? l10n.text("手机存储") : "/", path: isPhoneStorage ? path : "/")]
        for component in components.dropFirst(isPhoneStorage ? 1 : 0) {
            path += "/" + component
            levels.append(DirectoryLevel(name: String(component), path: path))
        }
        return levels
    }

    var body: some View {
        HStack(spacing: 8) {
            QuietIconButton(symbol: "chevron.left", help: l10n.text("上一级文件夹")) {
                model.loadFiles((model.path as NSString).deletingLastPathComponent)
            }
            .disabled(!model.online || model.busy || model.path == "/" || model.path == "/sdcard")
            .keyboardShortcut(.upArrow, modifiers: .command)

            Menu {
                Button(l10n.text("手机存储")) { model.loadFiles("/sdcard") }
                Button(l10n.text("根目录")) { model.loadFiles("/") }
                Divider()
                Button(l10n.text("前往文件夹…")) {
                    enteredPath = model.path
                    editingPath = true
                }
                Button(l10n.text("复制完整路径")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.path, forType: .string)
                }
            } label: {
                Label(l10n.text("目录导航"), systemImage: "internaldrive")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(l10n.text("前往文件夹或复制路径"))
            .accessibilityLabel(l10n.text("目录导航"))
            .disabled(!model.online || model.busy)

            FolderBreadcrumbLayout {
                ForEach(Array(levels.enumerated()), id: \.element.id) { index, level in
                    HStack(spacing: 4) {
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(HubStyle.muted)
                                .accessibilityHidden(true)
                        }
                        if level.path == model.path {
                            Text(verbatim: level.name)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 4)
                                .frame(minHeight: 24)
                                .help(level.path)
                                .accessibilityLabel(l10n.text("当前文件夹，{1}", level.name))
                        } else {
                            Button {
                                model.loadFiles(level.path)
                            } label: {
                                Text(verbatim: level.name)
                                    .padding(.horizontal, 4)
                                    .frame(minHeight: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(HubStyle.accent)
                            .disabled(!model.online || model.busy)
                            .help(level.path)
                            .accessibilityLabel(level.path == "/" ? l10n.text("根目录") : level.name)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            QuietIconButton(symbol: "arrow.clockwise", help: l10n.text("刷新文件夹")) { model.loadFiles() }
                .disabled(!model.online || model.busy)
                .keyboardShortcut("r", modifiers: .command)

            if model.online {
                Divider().overlay(HubStyle.line).frame(height: 14)
                Text(l10n.text("{1} 个项目", itemCount))
                    .font(.caption)
                    .foregroundStyle(HubStyle.muted)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .padding(.horizontal, HubStyle.workspaceInset)
        .padding(.vertical, 5)
        .frame(minHeight: 38)
        .background(HubStyle.workspaceTint)
        .sheet(isPresented: $editingPath) {
            VStack(alignment: .leading, spacing: 16) {
                FileSheetHeading(title: l10n.text("前往手机文件夹"), symbol: "folder")
                TextField(l10n.text("绝对路径"), text: $enteredPath).textFieldStyle(.roundedBorder).onSubmit { goToPath() }
                FileSheetActions {
                    Spacer()
                    Button(l10n.text("取消")) { editingPath = false }.keyboardShortcut(.cancelAction)
                    ToolbarAction(title: l10n.text("前往"), symbol: "arrow.right", prominent: true) { goToPath() }
                        .keyboardShortcut(.defaultAction)
                }
            }.fileSheet(width: 420)
        }
    }

    private func goToPath() {
        editingPath = false
        model.loadFiles(enteredPath)
    }
}

private struct FolderBreadcrumbLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width) { _, _ in }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        _ = arrange(subviews, width: bounds.width) { view, frame in
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat?,
                         place: (LayoutSubview, CGRect) -> Void) -> CGSize {
        let spacing: CGFloat = 4
        let available = width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for view in subviews {
            let ideal = view.sizeThatFits(.unspecified)
            let size = ideal.width > available
                ? view.sizeThatFits(ProposedViewSize(width: available, height: nil))
                : ideal
            if x > 0 && x + size.width > available {
                y += rowHeight
                x = 0
                rowHeight = 0
            }
            place(view, CGRect(origin: CGPoint(x: x, y: y), size: size))
            widestRow = max(widestRow, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: widestRow, height: y + rowHeight)
    }
}

struct FileLibraryView: View {
    @Environment(\.l10n) private var l10n
    @EnvironmentObject private var model: HubModel
    let files: [DeviceFile]
    @Binding var selection: Set<String>
    let gridView: Bool
    let searching: Bool
    let connect: () -> Void
    let download: ([DeviceFile]) -> Void
    let rename: (DeviceFile) -> Void
    let batchRename: ([DeviceFile]) -> Void
    let move: ([DeviceFile]) -> Void
    let trash: ([DeviceFile]) -> Void
    let upload: ([URL], HubModel.UploadTarget) -> Void
    @State private var selectionAnchor: String?
    @State private var uploadDropTargeted = false

    var body: some View {
        FinderDropArea(target: model.uploadTarget, isTargeted: $uploadDropTargeted, accept: upload) {
            fileContent
                .appLanguage(l10n.language)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if uploadDropTargeted, model.uploadTarget != nil {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(HubStyle.accent, lineWidth: 2)
                    .overlay(alignment: .top) {
                        Text(l10n.text("上传到 {1}", (model.path as NSString).lastPathComponent))
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                            .padding(.top, 12)
                    }
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: selection) { if $0.isEmpty { selectionAnchor = nil } }
        .task(id: model.onlineSerial) {
            if let serial = model.onlineSerial { await model.loadFilesWhenReady(for: serial) }
        }
    }

    private var fileContent: some View {
        VStack(spacing: 0) {
            if model.online, let failure = model.directoryFailure, !model.files.isEmpty {
                HStack(spacing: 12) {
                    WorkspaceNotice(message: l10n.text("无法读取文件夹「{1}」。{2}", (failure.path as NSString).lastPathComponent, failure.message), isError: true)
                    ToolbarAction(title: l10n.text("重试"), symbol: "arrow.clockwise") { model.loadFiles(failure.path) }
                        .disabled(model.busy)
                }.padding(.horizontal, HubStyle.workspaceInset).padding(.top, 8)
            }
            if !model.online {
                LibraryStateView(symbol: "cable.connector", title: l10n.text("连接你的 Android 手机"), detail: l10n.text("可通过 USB 或无线调试连接手机。")) {
                    ToolbarAction(title: l10n.text("连接设备"), symbol: "link", prominent: true, action: connect)
                }
            } else if files.isEmpty {
                if let failure = model.directoryFailure, model.files.isEmpty {
                    LibraryStateView(symbol: "exclamationmark.circle", title: l10n.text("无法读取文件夹"),
                                     detail: failure.message, isError: true) {
                        ToolbarAction(title: l10n.text("重新加载"), symbol: "arrow.clockwise", prominent: true) {
                            model.loadFiles(failure.path)
                        }.disabled(model.busy)
                    }
                } else if model.isLoadingDirectory {
                    LibraryStateView(symbol: nil, title: l10n.text("正在读取文件夹…")) { EmptyView() }
                } else if !model.hasLoadedDirectory {
                    LibraryStateView(symbol: "folder", title: l10n.text("文件夹待刷新")) {
                        ToolbarAction(title: l10n.text("刷新"), symbol: "arrow.clockwise") { model.loadFiles() }
                            .disabled(model.busy)
                    }
                } else {
                    LibraryStateView(symbol: searching ? "magnifyingglass" : "folder", title: searching ? l10n.text("没有找到匹配的文件") : l10n.text("文件夹中没有可显示的项目"), detail: searching ? l10n.text("换一个文件名试试。") : l10n.text("可从 Finder 拖入文件或文件夹。")) {
                        ToolbarAction(title: l10n.text("刷新"), symbol: "arrow.clockwise") { model.loadFiles() }
                    }
                }
            } else if gridView {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 145), spacing: 20)], alignment: .leading, spacing: 21) {
                        ForEach(files) { file in
                            Button { select(file) } label: {
                                FileTile(file: file, selected: selection.contains(file.id)).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .simultaneousGesture(TapGesture(count: 2).onEnded { open(file) })
                                .contextMenu { fileMenu(file) }
                                .accessibilityLabel(file.name)
                                .accessibilityAddTraits(selection.contains(file.id) ? .isSelected : [])
                                .accessibilityAction(named: file.isDirectory ? l10n.text("打开文件夹") : l10n.text("下载文件")) { open(file) }
                        }
                    }.padding(HubStyle.workspaceInset)
                        .background(scrollTracker)
                }
                .id(model.path)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text(l10n.text("名称")).frame(maxWidth: .infinity, alignment: .leading)
                        Text(l10n.text("种类")).frame(width: 95, alignment: .leading)
                        Text(l10n.text("大小")).frame(width: 90, alignment: .trailing)
                    }.font(.system(size: 11, weight: .medium)).foregroundStyle(HubStyle.muted)
                        .padding(.horizontal, HubStyle.workspaceInset).frame(height: 32)
                    Divider().overlay(HubStyle.line)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(files) { file in
                                Button { select(file) } label: {
                                    HStack(spacing: 10) {
                                        FileGlyph(file: file, size: 25)
                                        Text(file.name).font(.system(size: 12)).foregroundStyle(HubStyle.ink)
                                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                        Text(file.isDirectory ? l10n.text("文件夹") : fileType(file)).frame(width: 95, alignment: .leading)
                                        Text(file.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                            .monospacedDigit().frame(width: 90, alignment: .trailing)
                                    }
                                    .font(.system(size: 11)).foregroundStyle(HubStyle.muted)
                                    .padding(.horizontal, HubStyle.workspaceInset).frame(height: 40)
                                    .background {
                                        if selection.contains(file.id) {
                                            RoundedRectangle(cornerRadius: 7).fill(HubStyle.selection)
                                                .padding(.horizontal, 12)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .simultaneousGesture(TapGesture(count: 2).onEnded { open(file) })
                                    .contextMenu { fileMenu(file) }
                                    .accessibilityLabel(file.name)
                                    .accessibilityAddTraits(selection.contains(file.id) ? .isSelected : [])
                                    .accessibilityAction(named: file.isDirectory ? l10n.text("打开文件夹") : l10n.text("下载文件")) { open(file) }
                            }
                        }.padding(.vertical, 5).background(scrollTracker)
                    }
                    .id(model.path)
                }
            }
        }
    }

    private var scrollTracker: DirectoryScrollTracker {
        let directory = model.path
        let session = model.deviceSession
        return DirectoryScrollTracker(offset: model.directoryOffset(for: directory)) { offset in
            model.rememberDirectoryOffset(offset, for: directory, session: session)
        }
    }

    private func select(_ file: DeviceFile) {
        let modifiers = (NSApp.currentEvent?.modifierFlags ?? []).union(NSEvent.modifierFlags)
        if modifiers.contains(.shift), let anchor = selectionAnchor,
           let first = files.firstIndex(where: { $0.id == anchor }), let last = files.firstIndex(where: { $0.id == file.id }) {
            let range = Set(files[min(first, last)...max(first, last)].map(\.id))
            if modifiers.contains(.command) { selection.formUnion(range) }
            else { selection = range }
        } else {
            if modifiers.contains(.command) {
                if !selection.insert(file.id).inserted { selection.remove(file.id) }
            } else { selection = [file.id] }
            selectionAnchor = file.id
        }
    }

    private func open(_ file: DeviceFile) {
        guard !model.busy else { return }
        selection = [file.id]
        selectionAnchor = file.id
        if file.isDirectory { model.loadFiles(file.path) } else { download([file]) }
    }

    @ViewBuilder private func fileMenu(_ file: DeviceFile) -> some View {
        if file.isDirectory {
            Button { open(file) } label: { Label(l10n.text("打开文件夹"), systemImage: "folder") }
                .disabled(model.busy)
        }
        let selected = selection.contains(file.id) ? files.filter { selection.contains($0.id) } : [file]
        Button {
            download(selected)
        } label: {
            Label(selected.count > 1 ? l10n.text("下载 {1} 项…", selected.count) : (file.isDirectory ? l10n.text("下载文件夹…") : l10n.text("下载到 Mac…")),
                  systemImage: "arrow.down.to.line")
        }.disabled(model.busy || model.isLoadingDirectory)
        Divider()
        Button { rename(file) } label: { Label(l10n.text("重命名…"), systemImage: "pencil") }
            .disabled(model.uploadTarget == nil)
        if selected.count > 1 {
            Button { batchRename(selected) } label: { Label(l10n.text("批量重命名…"), systemImage: "pencil.line") }
                .disabled(model.uploadTarget == nil)
        }
        Button { move(selected) } label: { Label(l10n.text("移动到…"), systemImage: "folder") }
            .disabled(model.uploadTarget == nil)
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(file.path, forType: .string)
        } label: { Label(l10n.text("复制路径"), systemImage: "doc.on.doc") }
        Divider()
        Button { trash(selected) } label: { Label(l10n.text("移入回收站…"), systemImage: "trash") }
            .disabled(model.uploadTarget == nil)
    }
    private func fileType(_ file: DeviceFile) -> String {
        let ext = (file.name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? l10n.text("文件") : ext + l10n.text(" 文件")
    }
}

private struct DirectoryScrollTracker: NSViewRepresentable {
    let offset: CGFloat
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> Tracker {
        Tracker(offset: offset, onScroll: onScroll)
    }

    func updateNSView(_ view: Tracker, context: Context) {}

    final class Tracker: NSView {
        private let initialOffset: CGFloat
        private let onScroll: (CGFloat) -> Void
        private weak var observedClip: NSClipView?

        init(offset: CGFloat, onScroll: @escaping (CGFloat) -> Void) {
            initialOffset = offset
            self.onScroll = onScroll
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            observedClip = nil
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.observeScrollView() }
        }

        private func observeScrollView() {
            guard observedClip == nil, window != nil, let scroll = enclosingScrollView else { return }
            let clip = scroll.contentView
            if initialOffset > 0 {
                let proposed = CGRect(origin: CGPoint(x: clip.bounds.minX, y: initialOffset), size: clip.bounds.size)
                clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
                scroll.reflectScrolledClipView(clip)
            }
            observedClip = clip
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipScrolled),
                name: NSView.boundsDidChangeNotification, object: clip)
        }

        @objc private func clipScrolled() {
            if let observedClip { onScroll(max(0, observedClip.bounds.minY)) }
        }
    }
}

private struct FileTile: View {
    let file: DeviceFile
    let selected: Bool
    @State private var hovered = false
    var body: some View {
        VStack(spacing: 7) {
            FileGlyph(file: file, size: 62).padding(.top, 3)
            Text(file.name).font(.system(size: 11)).foregroundStyle(HubStyle.ink)
                .multilineTextAlignment(.center).lineLimit(2).truncationMode(.middle).frame(height: 31, alignment: .top)
        }.padding(.horizontal, 7).padding(.vertical, 5).frame(maxWidth: .infinity).frame(height: 110)
            .background(selected ? HubStyle.selection : hovered ? HubStyle.workspaceTint : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.13), value: hovered)
            .animation(.easeOut(duration: 0.13), value: selected)
    }
}

private final class PhotoGroupingCache {
    private struct Entry {
        let calendar: Calendar
        let items: [MediaItem]
        let groups: [PhotoDateGroup]
    }

    private var entries: [Bool: Entry] = [:]

    func groups(in items: [MediaItem], calendar: Calendar, isAlbum: Bool) -> [PhotoDateGroup] {
        if let entry = entries[isAlbum], entry.calendar == calendar, entry.items == items {
            return entry.groups
        }
        let groups = PhotoDateGroup.groups(in: items, calendar: calendar)
        entries[isAlbum] = Entry(calendar: calendar, items: items, groups: groups)
        return groups
    }
}

struct PhotoLibraryView: View {
    @Environment(\.l10n) private var l10n
    @EnvironmentObject private var model: HubModel
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    let items: [MediaItem]
    let allItems: [MediaItem]
    let resultIDs: Set<String>
    @Binding var selection: Set<String>
    @Binding var query: String
    let allQuery: String
    let searchPending: Bool
    let hasMore: Bool
    let hasMoreAll: Bool
    let loadNextPage: () -> Void
    let connect: () -> Void
    let preview: (MediaItem) -> Void
    @State private var selectionAnchor: String?
    @State private var selectionMode = false
    @State private var dateGroups = PhotoGroupingCache()
    @State private var visibleDays: [String?: Date] = [:]
    @State private var showsAlbums = false
    @State private var refreshDay: Date?
    @State private var layoutDay: Date?
    @AppStorage("compactPhotoGallery") private var compact = false
    private var allTitle: String { l10n.text("全部") + model.galleryNoun }
    private var searchPlaceholder: String {
        if model.photoAlbumID != nil { return l10n.text("搜索当前相册") }
        return model.showsVideos ? l10n.text("搜索视频") : l10n.text("搜索全部照片")
    }

    private var localCalendar: Calendar {
        var local = calendar
        local.timeZone = timeZone
        return local
    }

    var body: some View {
        if let client = model.photoLibrary {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Picker(l10n.text("图库类型"), selection: Binding(get: { model.showsVideos }, set: { model.selectGalleryVideos($0) })) {
                        Text(l10n.text("照片")).tag(false)
                        Text(l10n.text("视频")).tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 108).disabled(model.busy || model.galleryLoading)
                    albumPicker(client: client)
                    Spacer()
                    LibrarySearchField(placeholder: searchPlaceholder, query: $query)
                    Button(selectionMode ? l10n.text("完成选择") : l10n.text("多选")) { selectionMode.toggle() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(HubStyle.accent)
                    let allSelected = !resultIDs.isEmpty && resultIDs.isSubset(of: selection)
                    Button(allSelected ? l10n.text("取消选择") : l10n.text("全选当前结果")) {
                        if allSelected { selection.subtract(resultIDs) } else { selection.formUnion(resultIDs) }
                    }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(HubStyle.accent).disabled(items.isEmpty)
                    QuietIconButton(symbol: compact ? "square.grid.2x2" : "rectangle.grid.1x2",
                                    help: compact ? l10n.text("切换到标准视图") : l10n.text("切换到紧凑视图"), selected: compact) {
                        layoutDay = visibleDays[model.photoAlbumID]
                        compact.toggle()
                    }
                    QuietIconButton(symbol: "arrow.clockwise", help: l10n.text("刷新图库")) {
                        refreshDay = visibleDays[model.photoAlbumID]
                        model.reloadMedia(retaining: selection, near: refreshDay, query: query, calendar: localCalendar)
                    }.disabled(model.busy || model.galleryLoading)
                }.padding(.horizontal, HubStyle.workspaceInset).frame(height: HubStyle.controlBarHeight)
                    .background(HubStyle.workspaceTint)
                Divider().overlay(HubStyle.line)
                if model.galleryLoading {
                    WorkspaceNotice(message: l10n.text("正在核对手机图库…"), loading: true)
                        .padding(.horizontal, HubStyle.workspaceInset).padding(.top, 8)
                } else if let notice = model.galleryNotice {
                    WorkspaceNotice(message: l10n.text("图库核对失败，仍显示上次读取的内容。{1}", notice), isError: true)
                        .padding(.horizontal, HubStyle.workspaceInset).padding(.top, 8)
                }
                ZStack {
                    // Retain the native scroll view when visiting an album.
                    gallery(client: client, photos: allItems, albumID: nil, query: allQuery,
                            pending: model.photoAlbumID == nil && searchPending,
                            hasMore: model.photoAlbumID == nil ? hasMore : hasMoreAll)
                        .opacity(model.photoAlbumID == nil ? 1 : 0)
                        .allowsHitTesting(model.photoAlbumID == nil)
                        .accessibilityHidden(model.photoAlbumID != nil)
                    if let albumID = model.photoAlbumID {
                        gallery(client: client, photos: items, albumID: albumID, query: query,
                                pending: searchPending, hasMore: hasMore)
                            .id(albumID)
                    }
                }
            }
            .onChange(of: model.showsVideos) { _ in
                visibleDays = [:]
                showsAlbums = false
                refreshDay = nil
                selectionAnchor = nil
                selectionMode = false
            }
            .onChange(of: client.cacheID) { _ in
                visibleDays = [:]
                showsAlbums = false
                refreshDay = nil
                selectionAnchor = nil
            }
            .onChange(of: model.photoAlbumID) { _ in
                refreshDay = nil
                selectionAnchor = nil
                selectionMode = false
            }
        } else if model.online && model.galleryLoading {
            LibraryStateView(symbol: nil, title: l10n.text("正在读取手机图库…")) { EmptyView() }
        } else if model.online, let notice = model.galleryNotice {
            LibraryStateView(symbol: "exclamationmark.circle", title: l10n.text("无法读取手机图库"),
                              detail: notice, isError: true) {
                ToolbarAction(title: l10n.text("重新加载"), symbol: "arrow.clockwise", prominent: true) { model.reloadMedia() }
            }
        } else {
            LibraryStateView(symbol: "photo.on.rectangle", title: l10n.text("浏览手机照片"),
                              detail: model.online ? l10n.text("读取手机的 DCIM 和 Pictures 文件夹。") : l10n.text("可通过 USB 或无线调试连接手机。")) {
                if model.online {
                    ToolbarAction(title: l10n.text("扫描照片"), symbol: "arrow.clockwise", prominent: true) { model.reloadMedia() }
                } else {
                    ToolbarAction(title: l10n.text("连接设备"), symbol: "link", prominent: true, action: connect)
                }
            }
        }
    }

    @ViewBuilder private func gallery(client: ADBPhotoLibrary, photos: [MediaItem], albumID: String?,
                                      query: String, pending: Bool, hasMore: Bool) -> some View {
        if photos.isEmpty && pending {
            LibraryStateView(symbol: nil, title: l10n.text("正在搜索…")) { EmptyView() }
        } else if photos.isEmpty {
            VStack(spacing: 0) {
                LibraryStateView(symbol: query.isEmpty ? (model.showsVideos ? "film" : "photo") : "magnifyingglass",
                                  title: query.isEmpty ? l10n.text("还没有可访问的{1}", model.galleryNoun) : l10n.text("没有找到匹配的{1}", model.galleryNoun),
                                  detail: query.isEmpty ? (model.showsVideos ? l10n.text("图库读取 DCIM、Pictures 和 Movies 文件夹。") : l10n.text("图库读取手机的 DCIM 和 Pictures 文件夹。")) : "") { EmptyView() }
                loadMore(available: hasMore)
            }
        } else {
            let groups = dateGroups.groups(in: photos, calendar: localCalendar, isAlbum: albumID != nil)
            let isActive = albumID == model.photoAlbumID
            let savedDay = visibleDays[albumID]
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: compact ? 14 : 24) {
                        ForEach(groups) { group in
                            let layout = compact ? AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                                : AnyLayout(VStackLayout(alignment: .leading, spacing: 11))
                            layout {
                                Text(group.day, format: .dateTime.year().month().day().weekday())
                                    .font(.system(size: compact ? 12 : 14, weight: .semibold))
                                    .frame(width: compact ? 130 : nil, alignment: .leading)
                                    .accessibilityAddTraits(.isHeader)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 84 : 124,
                                                                      maximum: compact ? 104 : 164),
                                                             spacing: compact ? 10 : 16)],
                                          spacing: compact ? 10 : 18) {
                                    ForEach(group.items) { photoTile($0, client: client, isActive: isActive) }
                                }
                            }
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(key: PhotoDayFrames.self,
                                        value: [group.day: geometry.frame(in: .named("photoGalleryScroll"))])
                                }
                            }
                            .id(group.day)
                        }
                    }.padding(HubStyle.workspaceInset)
                    loadMore(available: hasMore)
                }
                .coordinateSpace(name: "photoGalleryScroll")
                .onPreferenceChange(PhotoDayFrames.self) { frames in
                    guard albumID == model.photoAlbumID else { return }
                    let first = frames.filter { $0.value.maxY > 0 }.min { $0.value.minY < $1.value.minY }
                    if let first { visibleDays[albumID] = first.key }
                }
                .onAppear {
                    guard albumID != nil, let savedDay,
                          let target = PhotoDateGroup.nearestDay(to: savedDay, in: groups) else { return }
                    DispatchQueue.main.async {
                        if albumID == model.photoAlbumID { proxy.scrollTo(target, anchor: .top) }
                    }
                }
                .onChange(of: model.photoRefreshID) { _ in
                    guard albumID == model.photoAlbumID, let day = refreshDay else { return }
                    refreshDay = nil
                    if let target = PhotoDateGroup.nearestDay(to: day, in: groups) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
                .onChange(of: compact) { _ in
                    guard albumID == model.photoAlbumID, let day = layoutDay else { return }
                    layoutDay = nil
                    if let target = PhotoDateGroup.nearestDay(to: day, in: groups) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
            }
        }
    }

    private func albumPicker(client: ADBPhotoLibrary) -> some View {
        let current = model.photoAlbums.first { $0.id == model.photoAlbumID }
        return Button { showsAlbums.toggle() } label: {
            Label(current?.name ?? allTitle, systemImage: "rectangle.stack")
                .font(.system(size: 11, weight: .medium)).lineLimit(1).frame(maxWidth: 130)
        }
        .help(current?.displayPath ?? l10n.text("选择相册"))
        .accessibilityLabel(current.map { l10n.text("相册，") + $0.name } ?? (l10n.text("相册，") + allTitle))
        .disabled(model.busy)
        .popover(isPresented: $showsAlbums, arrowEdge: .bottom) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    albumRow(nil, client: client)
                    ForEach(model.photoAlbums) { album in albumRow(album, client: client) }
                }.padding(8)
            }.frame(width: 324, height: min(380, CGFloat(model.photoAlbums.count + 1) * 56 + 16))
        }
    }

    private func albumRow(_ album: PhotoAlbum?, client: ADBPhotoLibrary) -> some View {
        let selected = album?.id == model.photoAlbumID
        return Button {
            model.selectPhotoAlbum(album?.id)
            showsAlbums = false
        } label: {
            HStack(spacing: 10) {
                if let album {
                    PhotoThumbnail(item: album.cover, client: client, allowsRetry: false)
                        .frame(width: 38, height: 38).accessibilityHidden(true)
                } else {
                    Image(systemName: "photo.on.rectangle").frame(width: 38, height: 38)
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(album?.name ?? allTitle).lineLimit(1)
                    if let album {
                        Text(album.displayPath).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                if let album {
                    Text("\(album.count) \(model.galleryUnit)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if selected { Image(systemName: "checkmark").foregroundStyle(HubStyle.accent).accessibilityHidden(true) }
            }
            .padding(.horizontal, 8).frame(height: 54)
            .background(selected ? HubStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(album?.path ?? allTitle)
    }

    @ViewBuilder private func loadMore(available: Bool) -> some View {
        if available {
            Button(query.isEmpty ? l10n.text("加载更多{1}", model.galleryNoun) : l10n.text("加载更多搜索结果"), action: loadNextPage)
                .disabled(model.busy).padding(.bottom, 24)
        }
    }

    private func photoTile(_ item: MediaItem, client: ADBPhotoLibrary, isActive: Bool) -> some View {
        let selected = selection.contains(item.id)
        return Button { select(item) } label: {
            VStack(alignment: .leading, spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    PhotoThumbnail(item: item, client: client, isActive: isActive)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(HubStyle.onAccent, HubStyle.accent).padding(7)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? HubStyle.accent : .clear, lineWidth: 2))
                Text(item.name).font(.system(size: 11))
                    .foregroundStyle(HubStyle.ink).lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(selected ? HubStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 4))
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded { preview(item) })
            .accessibilityLabel(item.name)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityAction(named: Text(item.isVideo ? l10n.text("播放视频") : l10n.text("预览照片"))) { preview(item) }
            .contextMenu {
                Button { preview(item) } label: {
                    Label(item.isVideo ? l10n.text("播放视频") : l10n.text("预览照片"), systemImage: item.isVideo ? "play" : "eye")
                }
                Divider()
                Button { model.export(item) } label: {
                    Label(item.isVideo ? l10n.text("导出原始视频…") : l10n.text("导出原图…"), systemImage: "square.and.arrow.up")
                }.disabled(model.busy)
            }
    }

    private func select(_ item: MediaItem) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift), let anchor = selectionAnchor,
           let a = items.firstIndex(where: { $0.id == anchor }), let b = items.firstIndex(where: { $0.id == item.id }) {
            selection.formUnion(items[min(a, b)...max(a, b)].map(\.id))
        } else if selectionMode || modifiers.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            selectionAnchor = item.id
        } else {
            selection = [item.id]; selectionAnchor = item.id
        }
    }
}

private struct PhotoDayFrames: PreferenceKey {
    static var defaultValue: [Date: CGRect] { [:] }
    static func reduce(value: inout [Date: CGRect], nextValue: () -> [Date: CGRect]) {
        value.merge(nextValue()) { _, latest in latest }
    }
}

private struct PhotoThumbnail: View {
    @Environment(\.l10n) private var l10n
    let item: MediaItem
    let client: ADBPhotoLibrary
    var allowsRetry = true
    var isActive = true
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var duration: TimeInterval?
    @State private var failed = false
    @State private var attempt = 0
    @State private var loadedRequest: String?
    var body: some View {
        GeometryReader { geometry in
            let pixels = Int(geometry.size.width * displayScale)
            let bucket = min(320, max(64, ((pixels + 63) / 64) * 64))
            let request = "\(client.cacheID)-\(item.id)-\(item.modifiedAt)-\(item.bytes)-\(attempt)-\(bucket)"
            ZStack {
                Color.primary.opacity(0.035)
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
                else if failed && allowsRetry && !item.isVideo {
                    Button { attempt += 1 } label: {
                        Label(l10n.text("重新加载"), systemImage: "arrow.clockwise").font(.system(size: 10)).foregroundStyle(.secondary)
                    }.buttonStyle(.borderless)
                }
                else {
                    Image(systemName: item.isVideo ? "film" : "photo")
                        .font(.system(size: 19, weight: .light))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.isVideo && allowsRetry {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                        if let duration, duration >= 0, duration < Double(Int.max) {
                            let total = Int(duration.rounded(.down))
                            let minutes = total / 60
                            Text(minutes >= 60
                                ? String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, total % 60)
                                : String(format: "%d:%02d", minutes, total % 60))
                        }
                    }
                    .font(.system(size: 10, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 4)).padding(5)
                }
            }
            .task(id: "\(isActive)-\(request)") {
                guard isActive, loadedRequest != request else { return }
                image = nil; duration = nil; failed = false
                do {
                    let value = try await PhotoImagePipeline.shared.image(client: client, item: item, kind: .thumbnail,
                                                                          pixels: bucket)
                    try Task.checkCancellation()
                    image = value.image
                    duration = value.duration
                    loadedRequest = request
                } catch { if !Task.isCancelled { failed = true } }
            }
        }.aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 2))
            .onDisappear { image = nil; loadedRequest = nil }
    }
}
