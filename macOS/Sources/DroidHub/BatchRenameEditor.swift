import SwiftUI
import DroidHubCore

struct BatchRenameRequest: Identifiable {
    let id = UUID()
    let files: [DeviceFile]
    let target: HubModel.UploadTarget
}

struct BatchRenameEditor: View {
    @Environment(\.l10n) private var l10n
    private enum Mode: String, CaseIterable {
        case affixes = "添加前后缀", replace = "查找替换", number = "顺序编号"
    }

    let request: BatchRenameRequest
    let readDirectory: () async throws -> [DeviceFile]
    let submit: (BatchRenameRule) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .affixes
    @State private var prefix = ""
    @State private var suffix = ""
    @State private var find = ""
    @State private var replacement = ""
    @State private var numberPrefix = ""
    @State private var directory: [DeviceFile]?
    @State private var loadError: String?

    private var rule: BatchRenameRule {
        switch mode {
        case .affixes: return .affixes(prefix: prefix, suffix: suffix)
        case .replace: return .replace(find: find, replacement: replacement)
        case .number: return .number(prefix: numberPrefix)
        }
    }

    var body: some View {
        let plan = directory.map { BatchRenamePlan(selection: request.files, directory: $0, rule: rule) }
        VStack(alignment: .leading, spacing: 14) {
            FileSheetHeading(title: l10n.text("批量重命名"), symbol: "pencil")
            Picker(l10n.text("改名方式"), selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text(l10n.text($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            fields
            Text(l10n.text("文件扩展名保持原样。")).font(.caption).foregroundStyle(HubStyle.muted)
            if let plan {
                preview(plan)
            } else {
                Group {
                    if let loadError {
                        LibraryStateView(symbol: "exclamationmark.circle", title: l10n.text("无法读取文件夹"),
                                          detail: loadError, isError: true) { EmptyView() }
                    } else {
                        LibraryStateView(symbol: nil, title: l10n.text("正在读取文件夹…")) { EmptyView() }
                    }
                }
                .frame(height: 245)
            }
            FileSheetActions {
                if let plan {
                    if plan.issues.isEmpty {
                        Text(l10n.text("将重命名 {1}/{2} 项", plan.changes.count, plan.rows.count)).foregroundStyle(.secondary)
                    } else {
                        Text(l10n.text("{1} 项需要处理", plan.issues.count)).foregroundStyle(HubStyle.error)
                    }
                }
                Spacer()
                Button(l10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                ToolbarAction(title: l10n.text("确认重命名"), symbol: "checkmark", prominent: true) { submit(rule) }
                    .disabled(!rule.isReady || plan?.canApply != true)
            }
        }
        .fileSheet(width: 680)
        .task {
            do { directory = try await readDirectory() }
            catch { if !Task.isCancelled { loadError = l10n.diagnostic(error.localizedDescription) } }
        }
    }

    @ViewBuilder private var fields: some View {
        HStack {
            switch mode {
            case .affixes:
                TextField(l10n.text("前缀"), text: $prefix)
                TextField(l10n.text("后缀"), text: $suffix)
            case .replace:
                TextField(l10n.text("查找文字"), text: $find)
                TextField(l10n.text("替换为（可留空）"), text: $replacement)
            case .number:
                TextField(l10n.text("编号前缀（可留空）"), text: $numberPrefix)
                Text(l10n.text("从 001 开始，按当前列表顺序")).foregroundStyle(.secondary)
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func preview(_ plan: BatchRenamePlan) -> some View {
        VStack(spacing: 0) {
            HStack {
                column(l10n.text("改名前"))
                column(l10n.text("改名后"))
                Text(l10n.text("状态")).frame(width: 160, alignment: .leading)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(HubStyle.muted)
            .padding(.horizontal, 12).padding(.vertical, 9)
            Divider().overlay(HubStyle.line)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(plan.rows) { row in
                        HStack {
                            column(row.file.name)
                            column(row.name)
                            Text(row.issue.map { l10n.text($0.rawValue) } ?? (row.changesName ? l10n.text("可重命名") : l10n.text("名称不变")))
                                .font(.caption)
                                .foregroundStyle(row.issue == nil ? HubStyle.muted : HubStyle.error)
                                .frame(width: 160, alignment: .leading)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        Divider().overlay(HubStyle.line)
                    }
                }
            }
        }
        .frame(height: 245)
        .background(HubStyle.workspaceTint, in: RoundedRectangle(cornerRadius: 8))
    }

    private func column(_ text: String) -> some View {
        Text(text).lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(text)
    }
}
