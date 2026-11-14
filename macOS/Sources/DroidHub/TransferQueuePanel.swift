import DroidHubCore
import SwiftUI

struct TransferQueuePanel: View {
    @Environment(\.l10n) private var l10n
    @ObservedObject var queue: TransferQueue
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(l10n.text("传输队列")).font(.system(size: 14, weight: .semibold))
                Text(queue.items.isEmpty ? l10n.text("暂无传输任务") : l10n.text("{1} 个项目", queue.items.count))
                    .foregroundStyle(HubStyle.muted)
                Spacer()
                if queue.unfinishedCount > 0 {
                    Button(l10n.text("重试未完成任务"), action: queue.retryUnfinished)
                        .disabled(queue.retryableUnfinishedCount == 0)
                        .help(queue.retryableUnfinishedCount == 0 ? l10n.text("连接并选择原手机后可重试") : l10n.text("继续文件夹和大文件的未完成传输"))
                }
                if !queue.items.isEmpty {
                    Button(l10n.text("清除已结束"), action: queue.clearFinished)
                        .disabled(!queue.items.contains { $0.state.canClear })
                }
                QuietIconButton(symbol: "xmark", help: l10n.text("收起传输队列"), action: close)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, HubStyle.workspaceInset)
            .frame(height: 34)
            .background(HubStyle.well)

            Divider().overlay(HubStyle.line)
            if let issue = queue.storageIssue {
                WorkspaceNotice(message: l10n.diagnostic(issue), isError: true)
                    .padding(.horizontal, HubStyle.workspaceInset).padding(.vertical, 6)
            } else if queue.unfinishedCount > 0, queue.retryableUnfinishedCount == 0, queue.visibleActiveID == nil {
                WorkspaceNotice(message: l10n.text("连接并选择原手机后，可重试未完成任务。"))
                    .padding(.horizontal, HubStyle.workspaceInset).padding(.vertical, 6)
            }
            if queue.items.count == 1, let item = queue.items.first {
                row(item).padding(.horizontal, HubStyle.workspaceInset)
            } else if !queue.items.isEmpty {
                ScrollViewReader { reader in
                    ScrollView {
                    LazyVStack(spacing: 0) {
                            ForEach(queue.items) { item in
                                VStack(spacing: 0) {
                                    row(item)
                                    Divider().overlay(HubStyle.line)
                                }
                                .id(item.id)
                            }
                        }
                        .padding(.horizontal, HubStyle.workspaceInset)
                    }
                    .onAppear {
                        if let id = queue.visibleActiveID { reader.scrollTo(id, anchor: .top) }
                    }
                    .onChange(of: queue.visibleActiveID) { id in
                        if let id { reader.scrollTo(id, anchor: .top) }
                    }
                }
                .frame(height: queue.items.count == 2 ? 110 : 150)
            }
        }
        .font(.system(size: 11))
        .background(HubStyle.canvas)
    }

    private func row(_ item: QueuedTransfer) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Label(item.name, systemImage: item.isDirectory
                      ? (item.isUpload ? "folder.badge.plus" : "folder")
                      : (item.isUpload ? "arrow.up" : "arrow.down"))
                    .fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    .accessibilityLabel("\(item.direction) \(item.name)")
                Text("\(item.direction) · \(item.device) · \(item.location)")
                    .foregroundStyle(HubStyle.muted).lineLimit(1).truncationMode(.middle)
                if let detail = item.detail {
                    Text(l10n.diagnostic(detail)).foregroundStyle(item.state == .failed ? HubStyle.error : HubStyle.muted)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(status(item))
                    Spacer(minLength: 6)
                    if let total = item.total {
                        Text("\(formattedBytes(item.bytes)) / \(formattedBytes(total))")
                            .monospacedDigit().foregroundStyle(HubStyle.muted)
                    }
                }
                if let total = item.total, total > 0 {
                    progressBar(item, total: total)
                }
                if let folder = item.folderProgress {
                    Text(l10n.text("已完成 {1}/{2} 个文件", folder.completedFiles, folder.totalFiles))
                        .foregroundStyle(HubStyle.muted).monospacedDigit()
                    if let path = folder.currentFile {
                        Text((path as NSString).lastPathComponent)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(HubStyle.muted)
                            .help(path)
                            .accessibilityLabel(l10n.text("当前文件 {1}", path))
                    }
                }
            }
            .frame(width: 220)

            HStack(spacing: 9) {
                if item.state.canPause {
                    Button(l10n.text("暂停")) { queue.pause(item.id) }
                        .accessibilityLabel(l10n.text("暂停{1} {2}", item.direction, item.name))
                        .help(item.isDirectory || item.uploadResumeID != nil || item.downloadCheckpoint != nil
                              ? l10n.text("暂停并保留传输断点") : l10n.text("继续时从头传输小文件"))
                } else if item.state == .paused {
                    Button(l10n.text("继续")) { queue.continueTransfer(item.id) }
                        .disabled(!queue.canContinue(item))
                        .help(item.deviceID == queue.connection?.deviceID ? l10n.text("继续这项任务") : l10n.text("连接并选择原手机后可继续"))
                        .accessibilityLabel(l10n.text("继续{1} {2}", item.direction, item.name))
                } else if item.state.canRetry {
                    Button(l10n.text("重试")) { queue.retry(item.id) }
                        .disabled(!queue.canRetry(item))
                        .help(retryHint(item))
                        .accessibilityLabel(l10n.text("重试{1} {2}", item.direction, item.name))
                }
                if item.state.canCancel {
                    Button(l10n.text("取消")) { queue.cancel(item.id) }
                        .accessibilityLabel(l10n.text("取消{1} {2}", item.direction, item.name))
                }
            }
            .buttonStyle(.borderless)
            .frame(width: 77, alignment: .trailing)
        }
        .padding(.vertical, 10)
    }

    private func progressBar(_ item: QueuedTransfer, total: Int64) -> some View {
        let fraction = min(1, max(0, Double(item.bytes) / Double(total)))
        return GeometryReader { geometry in
            Capsule().fill(HubStyle.line)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(item.state == .completed ? HubStyle.green : HubStyle.accent)
                        .frame(width: geometry.size.width * fraction)
                }
        }
        .frame(height: 5)
        .padding(.vertical, 3)
        .accessibilityRepresentation {
            ProgressView(value: fraction).accessibilityLabel(l10n.text("{1}进度", item.direction))
        }
    }

    private func formattedBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func retryHint(_ item: QueuedTransfer) -> String {
        if queue.canRetry(item) {
            if item.isDirectory { return l10n.text("跳过校验一致的文件，从断点继续未完成的大文件") }
            return item.uploadResumeID != nil || (item.downloadCheckpoint != nil && item.bytes > 0)
                ? l10n.text("源文件未变化时，从已保存的进度继续") : l10n.text("从头重试这个项目")
        }
        if case .session = item.deviceID, item.deviceID != queue.connection?.deviceID {
            return l10n.text("无法确认原设备身份，请重新选择传输项目")
        }
        if item.deviceID != queue.connection?.deviceID { return l10n.text("连接并选择原手机后可重试") }
        return l10n.text("已有同名上传任务，请等待该任务结束")
    }

    private func status(_ item: QueuedTransfer) -> String {
        switch item.state {
        case .waiting: return l10n.text("等待{1}", item.direction)
        case .transferring: return l10n.text("正在{1}", item.direction)
        case .verifying: return l10n.text("正在校验 SHA-256")
        case .committing: return l10n.text("正在校验并保存")
        case .pausing: return l10n.text("正在暂停")
        case .paused: return l10n.text("已暂停")
        case .cancelling: return l10n.text("正在取消")
        case .completed: return l10n.text("已完成")
        case .cancelled: return l10n.text("已取消")
        case .failed: return l10n.text("{1}失败", item.direction)
        case .skipped: return l10n.text("已跳过")
        case .interrupted: return l10n.text("已中断")
        }
    }
}
