import SwiftUI
import CoreGraphics
import DroidHubCore

struct PhotoPreviewContext: Identifiable {
    let id = UUID()
    let items: [MediaItem]
    let initialID: String
    let client: ADBPhotoLibrary
}

struct PhotoPreviewView: View {
    @Environment(\.l10n) private var l10n
    @EnvironmentObject private var model: HubModel
    let context: PhotoPreviewContext
    let close: () -> Void
    @State private var index: Int
    @State private var preview: DecodedPhotoImage?
    private var image: CGImage? { preview?.image }
    @State private var loading = true
    @State private var failure: String?
    @State private var attempt = 0
    @State private var zoom = 1.0

    init(context: PhotoPreviewContext, close: @escaping () -> Void) {
        self.context = context
        self.close = close
        _index = State(initialValue: context.items.firstIndex { $0.id == context.initialID } ?? 0)
    }

    private var item: MediaItem { context.items[index] }

    @ViewBuilder
    var body: some View {
        if context.items.isEmpty {
            VStack(spacing: 16) {
                Text(l10n.text("没有可预览的照片，请刷新图库。"))
                ToolbarAction(title: l10n.text("关闭"), symbol: "xmark", action: close).keyboardShortcut(.cancelAction)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(HubStyle.canvas)
        } else { viewer }
    }

    private var viewer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                QuietIconButton(symbol: "xmark", help: l10n.text("关闭预览（Esc）"), action: close)
                    .keyboardShortcut(.cancelAction)
                Text(item.name).font(.system(size: 14, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle).help(item.name)
                Spacer()
                ToolbarAction(title: item.isVideo ? l10n.text("导出原始视频") : l10n.text("导出原图"), symbol: "square.and.arrow.up", prominent: true) {
                    model.export(item, previewID: context.id)
                }
                .disabled(model.busy || model.photoLibrary?.cacheID != context.client.cacheID)
            }
            .padding(.leading, 77).padding(.trailing, HubStyle.workspaceInset)
            .frame(height: 48).background(HubStyle.workspaceTint)
            Divider().overlay(HubStyle.line)
            canvas
            exportStatus
            Divider().overlay(HubStyle.line)
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    if let size = preview?.originalSize {
                        Text("\(Int(size.width)) × \(Int(size.height)) ·")
                    }
                    Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    navigationButton(previous: true)
                    Text("\(index + 1) / \(context.items.count)").monospacedDigit()
                        .accessibilityLabel(l10n.text("第 {1} 项，共 {2} 项", index + 1, context.items.count))
                    navigationButton(previous: false)
                }
                HStack(spacing: 10) {
                    if !item.isVideo {
                        QuietIconButton(symbol: "minus.magnifyingglass", help: l10n.text("缩小预览")) { zoom = max(1, zoom - 0.5) }.disabled(image == nil || zoom == 1)
                        ToolbarAction(title: zoom == 1 ? l10n.text("适应窗口") : "\(zoom.formatted())×",
                                      symbol: "arrow.up.left.and.arrow.down.right") { zoom = 1 }
                            .help(l10n.text("恢复到适应窗口")).disabled(image == nil || zoom == 1)
                        QuietIconButton(symbol: "plus.magnifyingglass", help: l10n.text("放大预览")) { zoom = min(3, zoom + 0.5) }.disabled(image == nil || zoom >= 3)
                    }
                }.frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: 11)).foregroundStyle(HubStyle.muted)
            .padding(.horizontal, HubStyle.workspaceInset).frame(height: HubStyle.controlBarHeight)
            .background(HubStyle.workspaceTint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HubStyle.canvas)
        .foregroundStyle(HubStyle.ink)
        .tint(HubStyle.accent)
        .task(id: "\(item.id)-\(attempt)") { if !item.isVideo { await load(item) } }
    }

    private var canvas: some View {
        GeometryReader { geometry in
            ZStack {
                HubStyle.canvas
                if item.isVideo {
                    VideoPlaybackView(item: item, client: context.client).id(item.id)
                } else if let image {
                    let width = CGFloat(image.width)
                    let height = CGFloat(image.height)
                    let margin = HubStyle.workspaceInset * 2
                    let fit = max(0, min((geometry.size.width - margin) / width, (geometry.size.height - margin) / height))
                    ScrollView([.horizontal, .vertical], showsIndicators: zoom > 1) {
                        Image(decorative: image, scale: 1).resizable().interpolation(.high)
                            .frame(width: width * fit * zoom, height: height * fit * zoom)
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                            .accessibilityLabel(item.name)
                    }
                    .scrollDisabled(zoom == 1)
                    .id(item.id)
                } else if loading {
                    LibraryStateView(symbol: nil, title: l10n.text("正在加载预览…")) { EmptyView() }
                } else {
                    LibraryStateView(symbol: "exclamationmark.circle", title: l10n.text("无法预览这张照片"),
                                      detail: failure ?? "", isError: true) {
                        ToolbarAction(title: l10n.text("重新加载"), symbol: "arrow.clockwise") { attempt += 1 }
                    }
                }
            }
        }.clipped()
    }

    private func navigationButton(previous: Bool) -> some View {
        let label = item.isVideo ? (previous ? l10n.text("上一个视频") : l10n.text("下一个视频")) : (previous ? l10n.text("上一张照片") : l10n.text("下一张照片"))
        let enabled = previous ? index > 0 : index + 1 < context.items.count
        return QuietIconButton(symbol: previous ? "chevron.left" : "chevron.right", help: label) {
            navigate(previous ? -1 : 1)
        }
        .keyboardShortcut(previous ? .leftArrow : .rightArrow, modifiers: item.isVideo ? .option : [])
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    @ViewBuilder
    private var exportStatus: some View {
        if let export = model.previewExport, export.owner == context.id {
            Divider().overlay(HubStyle.line)
            HStack(spacing: 10) {
                if model.photoExportProgress != nil {
                    ProgressView().controlSize(.mini)
                    Text(l10n.text("正在导出"))
                    Text(export.filename).lineLimit(1).truncationMode(.middle).help(export.filename)
                    Spacer()
                    Button(l10n.text("取消导出")) { model.cancelPreviewExport(context.id) }.buttonStyle(.plain)
                } else if let result = model.photoExportResult {
                    Text(result.message(l10n))
                    Text(export.filename).lineLimit(1).truncationMode(.middle).help(export.filename)
                    Spacer()
                    if !model.exportedPhotos.isEmpty {
                        Button(l10n.text("在 Finder 中显示")) { model.revealExportedPhotos() }
                            .buttonStyle(.plain).foregroundStyle(HubStyle.accent)
                    }
                }
            }
            .font(.system(size: 11)).foregroundStyle(HubStyle.muted)
            .padding(.horizontal, HubStyle.workspaceInset).frame(height: 36)
            .background(HubStyle.workspaceTint)
        }
    }

    private func navigate(_ delta: Int) {
        let next = index + delta
        guard context.items.indices.contains(next) else { return }
        preview = nil
        loading = true
        zoom = 1
        index = next
    }

    @MainActor private func load(_ item: MediaItem) async {
        loading = true; failure = nil; preview = nil; zoom = 1
        do {
            let decoded = try await PhotoImagePipeline.shared.image(client: context.client, item: item, kind: .preview)
            try Task.checkCancellation()
            preview = decoded
        } catch {
            if !Task.isCancelled { failure = l10n.diagnostic(error.localizedDescription) }
        }
        if !Task.isCancelled { loading = false }
    }
}
