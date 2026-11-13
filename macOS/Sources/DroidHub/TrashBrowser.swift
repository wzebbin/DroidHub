import SwiftUI
import DroidHubCore

struct TrashMoveRequest: Identifiable {
    let id = UUID()
    let files: [DeviceFile]
    let target: HubModel.UploadTarget
}

struct TrashMoveConfirmation: View {
    @Environment(\.l10n) private var l10n
    let request: TrashMoveRequest
    let submit: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FileSheetHeading(title: l10n.text("移入回收站"), symbol: "trash")
            List(request.files) { file in
                Label(file.name, systemImage: file.isDirectory ? "folder" : "doc")
                    .lineLimit(1).help(file.name)
            }
            .fileSheetList(height: 190)
            FileSheetActions {
                Text(l10n.text("已选 {1} 项", request.files.count)).foregroundStyle(HubStyle.muted)
                Spacer()
                Button(l10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                ToolbarAction(title: l10n.text("移入回收站"), symbol: "trash", prominent: true, action: submit)
            }
        }
        .fileSheet(width: 490)
    }
}

struct TrashBrowser: View {
    @Environment(\.l10n) private var l10n
    @EnvironmentObject private var model: HubModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<UUID> = []
    @State private var confirmingRestore = false
    @State private var chosenRestore: RestoreSelection?
    @State private var confirmingDeletion: [TrashEntry]?
    @State private var confirmingClear: TrashClearRequest?
    let device: TransferDeviceID
    let submit: ([TrashEntry]) -> Void
    let submitChosen: ([TrashRestoreRow], HubModel.UploadTarget) -> Void
    let submitDeletion: ([TrashEntry]) -> Void
    let submitClear: (TrashClearRequest) -> Void

    private struct RestoreSelection {
        let entries: [TrashEntry]
        let target: HubModel.UploadTarget
    }

    var body: some View {
        if let confirmingClear {
            TrashDeleteConfirmation(entries: confirmingClear.entries, clearPhoneName: confirmingClear.phoneName,
                                    cancel: { self.confirmingClear = nil },
                                    submit: { submitClear(confirmingClear) })
        } else if let confirmingDeletion {
            TrashDeleteConfirmation(entries: confirmingDeletion, cancel: { self.confirmingDeletion = nil },
                                    submit: { submitDeletion(confirmingDeletion) })
        } else if let chosenRestore {
            restorePicker(chosenRestore)
        } else {
            browser
        }
    }

    @ViewBuilder private var browser: some View {
        let connected = model.transfers.connection?.deviceID == device
        let entries = connected ? model.trashEntries : []
        let selected = entries.filter { selection.contains($0.id) }
        VStack(alignment: .leading, spacing: 14) {
            FileSheetHeading(title: l10n.text("回收站"), symbol: "trash")
            if !connected || entries.isEmpty {
                LibraryStateView(symbol: connected ? "trash" : "link",
                                  title: connected ? l10n.text("回收站为空") : l10n.text("请连接原手机")) { EmptyView() }
                    .frame(height: 240)
                    .background(HubStyle.workspaceTint, in: RoundedRectangle(cornerRadius: 8))
            } else {
                List(selection: $selection) {
                    ForEach(entries) { entry in
                        HStack {
                            Image(systemName: entry.isDirectory ? "folder" : "doc")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.name).lineLimit(1)
                                Text(entry.original).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if entry.partiallyDeleted == true {
                                Text(l10n.text("部分内容已删除")).font(.caption).foregroundStyle(.orange)
                            }
                            Text(entry.date, format: .dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .help(entry.original)
                        .tag(entry.id)
                    }
                }
                .fileSheetList(height: 240)
            }
            FileSheetActions {
                Button(l10n.text("永久删除…"), role: .destructive) { confirmingDeletion = selected }
                    .disabled(selected.isEmpty || model.uploadTarget == nil || model.moveBatch?.isFinished == false
                              || model.trashDeletionBatch?.isFinished == false)
                Button(l10n.text("清空回收站…"), role: .destructive) {
                    confirmingClear = model.prepareTrashClear(for: device)
                }
                .disabled(entries.isEmpty || model.uploadTarget == nil || model.moveBatch?.isFinished == false
                          || model.trashDeletionBatch?.isFinished == false)
                if connected {
                    Text(selection.isEmpty ? l10n.text("{1} 项", entries.count) : l10n.text("已选 {1} 项", selected.count))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(l10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(l10n.text("恢复到原目录")) { confirmingRestore = true }
                    .disabled(selected.isEmpty || model.uploadTarget == nil || model.moveBatch?.isFinished == false)
                ToolbarAction(title: l10n.text("恢复到…"), symbol: "folder") {
                    guard let target = model.uploadTarget else { return }
                    chosenRestore = RestoreSelection(entries: selected, target: target)
                }
                .disabled(selected.isEmpty || model.uploadTarget == nil || model.moveBatch?.isFinished == false)
            }
        }
        .fileSheet(width: 620)
        .confirmationDialog(l10n.text("恢复 {1} 项到原目录？", selected.count), isPresented: $confirmingRestore) {
            Button(l10n.text("恢复 {1} 项", selected.count)) { submit(selected) }
            Button(l10n.text("取消"), role: .cancel) {}
        }
    }

    private func restorePicker(_ request: RestoreSelection) -> some View {
        MoveDirectoryPicker(title: l10n.text("恢复到…"), initialDirectory: request.target.directory,
                            subtitle: l10n.text("已选 {1} 项", request.entries.count), previewButton: l10n.text("预览恢复"),
                            confirmButton: l10n.text("确认恢复"),
                            read: { try await model.trashRestoreDirectories(at: $0, in: request.target) },
                            preview: { try await model.previewTrashRestore(request.entries, to: $0, in: request.target) },
                            canSubmit: { $0.preview.move != nil && $0.preview.issues.isEmpty },
                            rowContent: { row in restoreRow(row) },
                            cancel: { chosenRestore = nil }) { _, rows in
            if let rows { submitChosen(rows, request.target) }
        }
    }

    private func restoreRow(_ row: TrashRestoreRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(row.entry.name, systemImage: row.entry.isDirectory ? "folder" : "doc")
                .lineLimit(1).truncationMode(.middle)
            Text(l10n.text("原路径 {1}", row.entry.original)).help(row.entry.original)
            Text(l10n.text("恢复到 {1}", row.preview.destination)).help(row.preview.destination)
            if !row.preview.issues.isEmpty {
                Text(row.preview.issues.map(l10n.diagnostic).joined(separator: l10n.text("；"))).foregroundStyle(HubStyle.error)
            }
        }
        .font(.caption)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider() }
    }

}


private struct TrashDeleteConfirmation: View {
    @Environment(\.l10n) private var l10n
    let entries: [TrashEntry]
    var clearPhoneName: String?
    let cancel: () -> Void
    let submit: () -> Void
    @FocusState private var cancelFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FileSheetHeading(title: clearPhoneName == nil ? l10n.text("永久删除 {1} 项？", entries.count) : l10n.text("清空回收站？"),
                             symbol: "trash")
            if let clearPhoneName {
                LabeledContent(l10n.text("当前手机"), value: clearPhoneName)
                Text(l10n.text("共 {1} 项", entries.count))
            }
            Text(l10n.text("永久删除后无法恢复。")).foregroundStyle(.secondary)
            List(entries) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    Label(entry.name, systemImage: entry.isDirectory ? "folder" : "doc")
                    Text(entry.original).font(.caption).foregroundStyle(.secondary)
                }
                .lineLimit(1).truncationMode(.middle).help(entry.original)
            }
            .fileSheetList(height: 210)
            FileSheetActions {
                Spacer()
                Button(l10n.text("取消"), action: cancel)
                    .keyboardShortcut(.defaultAction)
                    .focused($cancelFocused)
                    .accessibilityHint(l10n.text("按回车取消"))
                Button(clearPhoneName == nil ? l10n.text("永久删除") : l10n.text("清空回收站"), role: .destructive, action: submit)
            }
        }
        .fileSheet(width: 570)
        .task { cancelFocused = true }
        .onExitCommand(perform: cancel)
    }
}

struct TrashDeletionResultView: View {
    @Environment(\.l10n) private var l10n
    @EnvironmentObject private var model: HubModel
    @Environment(\.dismiss) private var dismiss
    let device: TransferDeviceID

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let batch = model.trashDeletionBatch, batch.device == device {
                FileSheetHeading(title: batch.action + l10n.text("结果"), symbol: "list.bullet.rectangle")
                Text(l10n.text("已删除 {1}/{2} 项", batch.completed, batch.items.count)).foregroundStyle(.secondary)
                List(batch.items) { item in
                    HStack {
                        Text(item.entry.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(label(item.state)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .fileSheetList(height: 210)
                if let message = batch.blockingMessage {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
                FileSheetActions {
                    if !batch.isFinished, batch.checkIndex == nil {
                        Button(l10n.text("结束此批次")) { model.endTrashDeletion(); dismiss() }
                            .disabled(!model.canManageTrashDeletion)
                    }
                    Spacer()
                    Button(l10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
                    if !batch.isFinished {
                        ToolbarAction(title: batch.checkIndex == nil ? l10n.text("重试剩余项") : l10n.text("重新核对"),
                                      symbol: "arrow.clockwise", prominent: true) { model.retryTrashDeletion() }
                            .disabled(!model.canManageTrashDeletion)
                    }
                }
            } else {
                Text(l10n.text("请重新连接原手机以查看结果。")).foregroundStyle(.secondary)
                Button(l10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .fileSheet(width: 570)
    }

    private func label(_ state: TrashDeleteState) -> String {
        switch state {
        case .pending: return l10n.text("未执行")
        case .checking: return model.busy ? l10n.text("正在处理") : l10n.text("待核对")
        case .deleted: return l10n.text("已删除")
        case .present: return l10n.text("仍在回收站，可重试")
        case .partial: return l10n.text("部分内容已删除，剩余内容可重试")
        case .unknown: return l10n.text("无法确认，请重新核对")
        }
    }
}

private extension View {
    func fileSheetList(height: CGFloat) -> some View {
        scrollContentBackground(.hidden)
            .frame(height: height)
            .background(HubStyle.workspaceTint, in: RoundedRectangle(cornerRadius: 8))
    }
}
