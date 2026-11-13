import SwiftUI
import AppKit
import DroidHubCore

struct MoveDirectoryRequest: Identifiable {
    let id = UUID()
    let files: [DeviceFile]
    let target: HubModel.UploadTarget
}

struct MoveDirectoryPicker<Row: Identifiable, RowContent: View>: View {
    @Environment(\.l10n) private var l10n
    let title: String
    let source: String?
    let subtitle: String
    let previewButton: String
    let confirmButton: String
    let destinationIssue: (String) -> String?
    let read: (String) async throws -> [DeviceFile]
    let preview: ((String) async throws -> [Row])?
    let canSubmit: (Row) -> Bool
    let rowContent: (Row) -> RowContent
    let cancel: (() -> Void)?
    let submit: (String, [Row]?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var directory: String
    @State private var enteredPath: String
    @State private var children: [DeviceFile] = []
    @State private var loadedDirectory: String?
    @State private var loadError: String?
    @State private var showPreview = false
    @State private var previewRows: [Row]?
    @State private var previewError: String?

    init(title: String, initialDirectory: String, source: String? = nil, subtitle: String,
         previewButton: String, confirmButton: String, destinationIssue: @escaping (String) -> String? = { _ in nil },
         read: @escaping (String) async throws -> [DeviceFile], preview: ((String) async throws -> [Row])?,
         canSubmit: @escaping (Row) -> Bool, @ViewBuilder rowContent: @escaping (Row) -> RowContent,
         cancel: (() -> Void)? = nil, submit: @escaping (String, [Row]?) -> Void) {
        self.title = title
        self.source = source
        self.subtitle = subtitle
        self.previewButton = previewButton
        self.confirmButton = confirmButton
        self.destinationIssue = destinationIssue
        self.read = read
        self.preview = preview
        self.canSubmit = canSubmit
        self.rowContent = rowContent
        self.cancel = cancel
        self.submit = submit
        _directory = State(initialValue: initialDirectory)
        _enteredPath = State(initialValue: initialDirectory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FileSheetHeading(title: title, symbol: "folder")
            if showPreview {
                batchPreview
            } else {
                directoryBrowser
            }
        }
        .fileSheet(width: preview == nil ? 510 : 620)
    }

    private var directoryBrowser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(subtitle)
                .foregroundStyle(HubStyle.muted).lineLimit(1).truncationMode(.middle)
            HStack {
                Button(l10n.text("上一级")) { navigate((directory as NSString).deletingLastPathComponent) }
                    .disabled(directory == "/")
                Button(l10n.text("手机存储")) { navigate("/sdcard") }
                MovePathField(text: $enteredPath) { navigate(enteredPath) }
                    .frame(height: 22)
                ToolbarAction(title: l10n.text("前往"), symbol: "arrow.right") { navigate(enteredPath) }
                    .disabled(!enteredPath.hasPrefix("/"))
            }
            Group {
                if let loadError {
                    LibraryStateView(symbol: "exclamationmark.circle", title: l10n.text("无法读取目标目录"),
                                      detail: loadError, isError: true) { EmptyView() }
                } else if loadedDirectory != directory {
                    LibraryStateView(symbol: nil, title: l10n.text("正在读取目标目录…")) { EmptyView() }
                } else if children.isEmpty {
                    LibraryStateView(symbol: "folder", title: l10n.text("没有子文件夹")) { EmptyView() }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(children) { child in
                                Button { navigate(child.path) } label: {
                                    HStack {
                                        Label(child.name, systemImage: "folder").lineLimit(1)
                                        Spacer()
                                        Image(systemName: "chevron.right").foregroundStyle(HubStyle.muted)
                                    }.padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .frame(height: 230)
            .background(HubStyle.workspaceTint, in: RoundedRectangle(cornerRadius: 8))
            FileSheetActions {
                if loadedDirectory == directory, let destinationIssue = destinationIssue(directory) {
                    Text(destinationIssue).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(l10n.text("取消"), action: cancelPicker).keyboardShortcut(.cancelAction)
                ToolbarAction(title: previewButton, symbol: preview == nil ? "checkmark" : "eye", prominent: true) {
                    if preview != nil {
                        previewRows = nil
                        previewError = nil
                        showPreview = true
                    } else {
                        submit(directory, nil)
                    }
                }
                    .disabled(loadedDirectory != directory || enteredPath != directory || destinationIssue(directory) != nil)
            }
        }
        .task(id: directory) {
            let path = directory
            loadedDirectory = nil
            loadError = nil
            do {
                let result = try await read(path)
                try Task.checkCancellation()
                children = result
                loadedDirectory = path
            } catch {
                if !Task.isCancelled { loadError = l10n.diagnostic(error.localizedDescription) }
            }
        }
    }

    private var batchPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let source { LabeledContent(l10n.text("源目录"), value: source) }
            LabeledContent(l10n.text("目标目录"), value: directory)
            Group {
                if let previewRows {
                    MoveStatusList {
                        ForEach(previewRows, content: rowContent)
                    }
                } else if let previewError {
                    LibraryStateView(symbol: "exclamationmark.circle", title: l10n.text("无法生成预览"),
                                      detail: previewError, isError: true) { EmptyView() }
                } else {
                    LibraryStateView(symbol: nil, title: l10n.text("正在生成预览…")) { EmptyView() }
                }
            }
            .frame(height: 230)
            FileSheetActions {
                Button(l10n.text("返回选目录")) { showPreview = false }
                Spacer()
                Button(l10n.text("取消"), action: cancelPicker).keyboardShortcut(.cancelAction)
                ToolbarAction(title: confirmButton, symbol: "checkmark", prominent: true) {
                    if let previewRows { submit(directory, previewRows) }
                }
                .disabled(previewRows.map { !$0.isEmpty && $0.allSatisfy(canSubmit) } != true)
            }
        }
        .task {
            guard let preview else { return }
            do {
                let rows = try await preview(directory)
                try Task.checkCancellation()
                previewRows = rows
            } catch {
                if !Task.isCancelled { previewError = l10n.diagnostic(error.localizedDescription) }
            }
        }
    }

    private func cancelPicker() {
        if let cancel { cancel() } else { dismiss() }
    }

    private func navigate(_ path: String) {
        guard path.hasPrefix("/") else { return }
        let normalized = (path as NSString).standardizingPath
        directory = normalized
        enteredPath = normalized
    }
}


struct BatchMoveResultRequest: Identifiable {
    let id = UUID()
    let device: TransferDeviceID
}

struct BatchMoveResultView: View {
    @Environment(\.l10n) private var l10n
    @EnvironmentObject private var model: HubModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDiscard = false
    let device: TransferDeviceID

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let batch = model.moveBatch, batch.device == device {
                FileSheetHeading(title: batch.trash.map { $0.action.title + l10n.text("结果") } ?? l10n.text("批量移动结果"),
                                 symbol: "list.bullet.rectangle")
                result(batch)
            } else {
                Text(l10n.text("请重新连接原手机以查看结果。")).foregroundStyle(.secondary)
                Button(l10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .fileSheet(width: 620)
    }

    private func result(_ batch: RemoteMoveBatch) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if batch.trash == nil { LabeledContent(l10n.text("源目录"), value: batch.source) }
            if batch.trash == nil || batch.trash?.action == .restoreToDirectory {
                LabeledContent(l10n.text("目标目录"), value: batch.destination)
            }
            Text(l10n.text("{1} {2}/{3} 项", batch.trash?.action.completedLabel ?? l10n.text("已移动"), batch.completed, batch.moves.count))
                .foregroundStyle(.secondary)
            MoveStatusList {
                ForEach(batch.moves.indices, id: \.self) { index in
                    moveStatusRow(batch.moves[index].name, status: status(batch, index: index),
                                  isIssue: batch.failedAt == index || (batch.checking && !model.busy && index == batch.completed))
                }
            }
            if let detail = batch.detail { Text(l10n.diagnostic(detail)).font(.caption).foregroundStyle(.secondary) }
            FileSheetActions {
                if !batch.isFinished && batch.canDiscard {
                    Button(l10n.text("结束此批次")) { confirmDiscard = true }.disabled(!model.canManageMoveBatch)
                }
                Spacer()
                Button(l10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
                if !batch.isFinished {
                    ToolbarAction(title: batch.checking ? l10n.text("重新核对") : l10n.text("重试剩余项"), symbol: "arrow.clockwise",
                                  prominent: true) { model.retryBatchMove() }
                        .disabled(!model.canManageMoveBatch)
                }
            }
        }
        .confirmationDialog(l10n.text("结束这次操作？"), isPresented: $confirmDiscard) {
            Button(l10n.text("结束此批次"), role: .destructive) {
                model.clearMoveBatch()
                dismiss()
            }
            Button(l10n.text("取消"), role: .cancel) {}
        } message: {
            Text(batch.trash == nil ? l10n.text("已移动的项目会留在目标目录。") : l10n.text("已完成的项目会保留当前位置。"))
        }
    }

    private func status(_ batch: RemoteMoveBatch, index: Int) -> String {
        if index < batch.completed { return batch.trash?.action.completedLabel ?? l10n.text("已移动") }
        if index == batch.completed && batch.checking { return model.busy ? l10n.text("正在处理") : l10n.text("待核对") }
        if batch.failedAt == index { return l10n.text("失败") }
        return l10n.text("未执行")
    }
}

private struct MoveStatusList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) { content }
        }
        .frame(height: 230)
        .background(HubStyle.workspaceTint, in: RoundedRectangle(cornerRadius: 8))
    }
}

func moveStatusRow(_ name: String, status: String, isIssue: Bool) -> some View {
    VStack(spacing: 0) {
        HStack {
            Text(name).lineLimit(1).truncationMode(.middle).help(name)
            Spacer()
            Text(status).font(.caption).foregroundStyle(isIssue ? HubStyle.error : HubStyle.muted)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        Divider().overlay(HubStyle.line)
    }
}


private struct MovePathField: NSViewRepresentable {
    @Environment(\.l10n) private var l10n
    @Binding var text: String
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isEditable = true
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        context.coordinator.monitorSelectAll(in: field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        let placeholder = l10n.text("目标目录路径")
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        if field.stringValue != text { field.stringValue = text }
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MovePathField
        private var monitor: Any?

        init(parent: MovePathField) { self.parent = parent }

        func monitorSelectAll(in field: NSTextField) {
            // Handle the key before the file list's Select All menu can claim it.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak field] event in
                let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
                guard flags == .command, event.charactersIgnoringModifiers?.lowercased() == "a",
                      let field, let window = field.window, window.isKeyWindow,
                      let editor = field.currentEditor(), window.firstResponder === editor else { return event }
                editor.selectAll(nil)
                return nil
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.submit()
            return true
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
