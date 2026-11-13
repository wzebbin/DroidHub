import AVKit
import SwiftUI
import DroidHubCore

struct VideoPlaybackView: View {
    @Environment(\.l10n) private var l10n
    @EnvironmentObject private var model: HubModel
    let item: MediaItem
    let client: ADBPhotoLibrary

    @State private var player: AVPlayer?
    @State private var directory: URL?
    @State private var downloaded: Int64 = 0
    @State private var checkingFormat = false
    @State private var failure: String?
    @State private var request: UUID? = UUID()

    var body: some View {
        Group {
            if let player, let currentItem = player.currentItem {
                NativeVideoPlayer(player: player)
                    .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime,
                                                                     object: currentItem)
                        .receive(on: DispatchQueue.main)) { _ in
                        playbackFailed(currentItem)
                    }
                    .onReceive(currentItem.publisher(for: \.status).receive(on: DispatchQueue.main)) { status in
                        if status == .failed { playbackFailed(currentItem) }
                    }
            } else if let failure {
                LibraryStateView(symbol: "exclamationmark.circle", title: l10n.text("无法播放视频"),
                                  detail: failure, isError: true) {
                    ToolbarAction(title: l10n.text("重新加载"), symbol: "arrow.clockwise") { start() }
                }
            } else if request == nil {
                LibraryStateView(symbol: "film", title: l10n.text("已取消下载")) {
                    ToolbarAction(title: l10n.text("重新加载"), symbol: "arrow.clockwise") { start() }
                }
            } else {
                VStack(spacing: 12) {
                    if checkingFormat {
                        ProgressView().controlSize(.small)
                        Text(l10n.text("正在打开视频…"))
                    } else {
                        ProgressView(value: Double(downloaded), total: Double(max(item.bytes, 1)))
                            .frame(width: 250)
                        Text(l10n.text("正在下载视频到 Mac"))
                        Text("\(byteCount(downloaded)) / \(byteCount(item.bytes))").monospacedDigit()
                    }
                    Button(l10n.text("取消下载")) { request = nil }
                }
                .font(.callout).foregroundStyle(HubStyle.muted)
                .accessibilityIdentifier("video-download")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: request) {
            guard let request else { return }
            do {
                try await model.videoPreviewFiles.run { folder in await load(request, in: folder) }
            } catch {
                if !Task.isCancelled, self.request == request {
                    failure = l10n.text("无法创建视频预览文件。{1}", l10n.diagnostic(error.localizedDescription))
                }
            }
        }
        .onDisappear { releasePlayback() }
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func start() {
        downloaded = 0
        checkingFormat = false
        failure = nil
        request = UUID()
    }

    @MainActor private func load(_ id: UUID, in folder: URL) async {
        let file = folder.appendingPathComponent(item.name)
        defer {
            if directory != folder { try? FileManager.default.removeItem(at: folder) }
        }
        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try await client.downloadVideo(item, to: file) { progress in
                if case let .transferring(bytes, _) = progress {
                    await MainActor.run {
                        if request == id { downloaded = bytes }
                    }
                }
            }
            try Task.checkCancellation()
            guard request == id else { return }
            checkingFormat = true
            let asset = AVURLAsset(url: file)
            guard try await asset.load(.isPlayable), try await !asset.loadTracks(withMediaType: .video).isEmpty else {
                throw HubError.message(l10n.text("macOS 无法播放这个视频，可以导出原始文件。"))
            }
            try Task.checkCancellation()
            guard request == id else { return }
            let playback = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            directory = folder
            player = playback
            playback.play()
        } catch {
            guard !Task.isCancelled, request == id else { return }
            if checkingFormat {
                failure = l10n.text("macOS 无法播放这个视频，可以导出原始文件。")
            } else {
                failure = l10n.text("下载视频失败。{1}", l10n.diagnostic(error.localizedDescription))
            }
        }
    }

    private func playbackFailed(_ item: AVPlayerItem) {
        guard player?.currentItem === item else { return }
        releasePlayback()
        failure = l10n.text("macOS 无法播放这个视频，可以导出原始文件。")
    }

    private func releasePlayback() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
            self.directory = nil
        }
    }
}

private struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}
