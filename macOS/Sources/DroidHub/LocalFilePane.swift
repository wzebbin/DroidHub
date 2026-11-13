import DroidHubCore
import AppKit
import SwiftUI

struct LocalFilePane: View {
    @Environment(\.l10n) private var l10n
    @Binding var directory: URL
    let queue: TransferQueue
    let uploadTarget: HubModel.UploadTarget?
    let upload: ([URL], HubModel.UploadTarget) -> Void

    @State private var entries: [Entry] = []
    @State private var selected = Set<URL>()
    @State private var refreshID = UUID()
    @State private var loadedDirectory: URL?
    @State private var readError: String?

    private struct Entry: Identifiable {
        var id: URL { url }
        let url: URL
        let isDirectory: Bool
    }

    private struct Request: Equatable {
        let directory: URL
        let refreshID: UUID
    }

    var body: some View {
        let selection = entries.filter { selected.contains($0.url) }.map(\.url)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                QuietIconButton(symbol: "chevron.left", help: l10n.text("Mac 上一级文件夹")) {
                    navigate(directory.deletingLastPathComponent())
                }.disabled(directory.path == "/")
                Label("Mac", systemImage: "desktopcomputer").font(.system(size: 11, weight: .medium))
                Text(directory.lastPathComponent.isEmpty ? "/" : directory.lastPathComponent)
                    .font(.caption).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    .help(directory.path)
                Spacer(minLength: 0)
                QuietIconButton(symbol: "folder", help: l10n.text("选择 Mac 文件夹"), action: chooseFolder)
                QuietIconButton(symbol: "arrow.clockwise", help: l10n.text("刷新 Mac 文件夹")) { refreshID = UUID() }
            }.padding(.horizontal, 12).frame(height: HubStyle.controlBarHeight)
                .background(HubStyle.workspaceTint)
            Divider().overlay(HubStyle.line)
            if loadedDirectory != directory {
                LibraryStateView(symbol: nil, title: l10n.text("正在读取 Mac 文件夹…")) { EmptyView() }
            } else if let readError {
                LibraryStateView(symbol: "exclamationmark.circle", title: l10n.text("无法读取 Mac 文件夹"),
                                  detail: readError, isError: true) {
                    ToolbarAction(title: l10n.text("重新加载"), symbol: "arrow.clockwise") { refreshID = UUID() }
                }
            } else if entries.isEmpty {
                LibraryStateView(symbol: "folder", title: l10n.text("Mac 文件夹为空")) { EmptyView() }
            } else {
                List(entries, selection: $selected) { entry in
                    Label(entry.url.lastPathComponent, systemImage: entry.isDirectory ? "folder" : "doc")
                        .lineLimit(1).truncationMode(.middle).tag(entry.url)
                        .help(entry.url.path)
                        .onTapGesture(count: 2) { if entry.isDirectory { navigate(entry.url) } }
                        .contextMenu {
                            if entry.isDirectory {
                                Button { navigate(entry.url) } label: { Label(l10n.text("打开 Mac 文件夹"), systemImage: "folder") }
                            }
                        }
                }.listStyle(.inset).scrollContentBackground(.hidden)
            }
            Divider()
            HStack {
                Text(selection.isEmpty ? l10n.text("{1} 个项目", entries.count) : l10n.text("已选 {1} 项", selection.count))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                ToolbarAction(title: selection.isEmpty ? l10n.text("上传到手机") : l10n.text("上传 {1} 项", selection.count),
                              symbol: "arrow.right") {
                    if let uploadTarget { upload(selection, uploadTarget) }
                }.disabled(selection.isEmpty || loadedDirectory != directory || uploadTarget == nil)
            }.padding(.horizontal, 12).frame(height: 40)
        }
        .background(HubStyle.canvas)
        .task(id: Request(directory: directory, refreshID: refreshID)) {
            let current = directory
            do {
                let result = try await Self.readDirectory(current)
                guard !Task.isCancelled, current == directory else { return }
                entries = result
                selected.formIntersection(Set(result.map(\.url)))
                readError = nil
            } catch {
                guard !Task.isCancelled, current == directory else { return }
                entries = []
                selected = []
                readError = l10n.text("无法读取这个 Mac 文件夹，请选择其他位置。")
            }
            loadedDirectory = current
        }
        .onReceive(queue.didDownload) { file in
            if file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL {
                refreshID = UUID()
            }
        }
    }

    private static func readDirectory(_ directory: URL) async throws -> [Entry] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                               options: .skipsHiddenFiles)
        try Task.checkCancellation()
        return urls.map {
            Entry(url: $0, isDirectory: (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
        }.sorted { first, second in
            if first.isDirectory != second.isDirectory { return first.isDirectory }
            return first.url.lastPathComponent.localizedStandardCompare(second.url.lastPathComponent) == .orderedAscending
        }
    }

    private func navigate(_ target: URL) {
        guard target != directory else { return }
        selected = []
        entries = []
        directory = target
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = l10n.text("选择 Mac 文件夹")
        panel.prompt = l10n.text("选择")
        panel.directoryURL = directory
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { navigate(url) }
    }
}
