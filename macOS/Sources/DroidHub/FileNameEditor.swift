import SwiftUI
import DroidHubCore

struct FileNameRequest: Identifiable {
    let id = UUID()
    let file: DeviceFile?
    let target: HubModel.UploadTarget
}

struct FileNameEditor: View {
    @Environment(\.l10n) private var l10n
    let request: FileNameRequest
    let submit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var nameFocused: Bool

    init(request: FileNameRequest, submit: @escaping (String) -> Void) {
        self.request = request
        self.submit = submit
        _name = State(initialValue: request.file.map { RemoteEntryName.editableParts(of: $0).stem } ?? "")
    }

    private var suffix: String { request.file.map { RemoteEntryName.editableParts(of: $0).suffix } ?? "" }
    private var valid: Bool {
        if let file = request.file { return (try? RemoteEntryName.renamed(file, stem: name)) != nil }
        return (try? RemoteEntryName.validate(name)) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FileSheetHeading(title: request.file == nil ? l10n.text("新建文件夹") : l10n.text("重命名"),
                             symbol: request.file == nil ? "folder.badge.plus" : "pencil")
            HStack(spacing: 8) {
                TextField(l10n.text("名称"), text: $name).textFieldStyle(.plain)
                    .focused($nameFocused)
                    .onSubmit(confirm)
                if !suffix.isEmpty {
                    Text(suffix).foregroundStyle(HubStyle.muted)
                        .accessibilityLabel(l10n.text("保留扩展名 {1}", suffix))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(HubStyle.workspaceTint, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(HubStyle.line).allowsHitTesting(false))
            FileSheetActions {
                Spacer()
                Button(l10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                ToolbarAction(title: request.file == nil ? l10n.text("创建") : l10n.text("确定"), symbol: "checkmark",
                              prominent: true, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
        }
        .fileSheet(width: 420)
        .task { nameFocused = true }
    }

    private func confirm() {
        if valid { submit(name) }
    }
}
