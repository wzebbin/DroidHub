import AppKit
import SwiftUI
import DroidHubCore

@MainActor
struct ToolSettings: View {
    @Environment(\.l10n) private var l10n
    @ObservedObject private var model: HubModel
    @Binding var appearance: AppAppearance
    @Binding var language: AppLanguage
    @State private var adbPath: String
    @State private var scrcpyPath: String
    @State private var showAdvanced = false
    @AppStorage(TransferQueue.autoResumeKey) private var autoResumeTransfers = false
    init(model: HubModel, appearance: Binding<AppAppearance>, language: Binding<AppLanguage>) {
        self.model = model
        _appearance = appearance
        _language = language
        _adbPath = State(initialValue: model.adbPath)
        _scrcpyPath = State(initialValue: model.scrcpyPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            settingsSection(l10n.text("语言")) {
                HStack(spacing: 12) {
                    settingsIcon("globe")
                    Text(l10n.text("界面语言")).font(.system(size: 13, weight: .medium))
                        .accessibilityHidden(true)
                    Spacer(minLength: 12)
                    Picker(l10n.text("界面语言"), selection: $language) {
                        ForEach(AppLanguage.allCases, id: \.self) { option in
                            Text(option.name).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(HubStyle.workspaceTint, in: RoundedRectangle(cornerRadius: 10))
            }

            settingsSection(l10n.text("外观")) {
                HStack(spacing: 12) {
                    appearanceOption(l10n.text("跟随系统"), mode: .system)
                    appearanceOption(l10n.text("浅色"), mode: .light)
                    appearanceOption(l10n.text("深色"), mode: .dark)
                }
            }

            settingsSection(l10n.text("连接工具")) {
                VStack(spacing: 0) {
                    toolStatus("ADB", subtitle: l10n.text("设备连接与文件传输"),
                               symbol: "cable.connector", executable: "adb", activePath: model.adbPath)
                    Divider().overlay(HubStyle.line).padding(.horizontal, 16)
                    toolStatus("scrcpy", subtitle: l10n.text("手机投屏"),
                               symbol: "display", executable: "scrcpy", activePath: model.scrcpyPath)
                }
                .background(HubStyle.workspaceTint, in: RoundedRectangle(cornerRadius: 10))
            }

            settingsSection(l10n.text("文件传输")) {
                Toggle(isOn: $autoResumeTransfers) {
                    HStack(spacing: 12) {
                        settingsIcon("arrow.clockwise")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(l10n.text("重连后自动继续")).font(.system(size: 13, weight: .medium))
                            Text(l10n.text("同一台手机重连时，继续因断线中断的任务。"))
                                .font(.system(size: 11)).foregroundStyle(HubStyle.muted)
                        }
                        Spacer(minLength: 12)
                    }
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(HubStyle.workspaceTint, in: RoundedRectangle(cornerRadius: 10))
            }

            VStack(alignment: .leading, spacing: 12) {
                Divider().overlay(HubStyle.line)
                Button {
                    showAdvanced = true
                } label: {
                    HStack(spacing: 8) {
                        Text(l10n.text("高级设置"))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(HubStyle.accent)
                            .accessibilityHidden(true)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(HubStyle.workspaceInset)
        .frame(width: 560)
        .foregroundStyle(HubStyle.ink)
        .tint(HubStyle.accent)
        .background(HubStyle.canvas)
        .sheet(isPresented: $showAdvanced) {
            AdvancedToolSettings(model: model, adbPath: $adbPath, scrcpyPath: $scrcpyPath)
        }
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 14, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func appearanceOption(_ title: String, mode: AppAppearance) -> some View {
        let selected = appearance == mode
        return Button {
            appearance = mode
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                appearancePreview(dark: mode == .dark)
                    .overlay {
                        if mode == .system {
                            appearancePreview(dark: true)
                                .mask {
                                    HStack(spacing: 0) {
                                        Color.clear
                                        Color.white
                                    }
                                }
                        }
                    }
                    .frame(height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(HubStyle.line))
                    .accessibilityHidden(true)

                HStack {
                    Text(title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(HubStyle.accent)
                        .opacity(selected ? 1 : 0)
                        .accessibilityHidden(true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? HubStyle.selection : HubStyle.workspaceTint, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func appearancePreview(dark: Bool) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(HubStyle.previewColor(\.muted, dark: dark).opacity(0.55))
                    .frame(width: 12, height: 3)
                RoundedRectangle(cornerRadius: 2)
                    .fill(HubStyle.previewColor(\.selection, dark: dark))
                    .frame(width: 17, height: 5)
                Spacer(minLength: 0)
            }
            .padding(.top, 9)
            .frame(width: 26, alignment: .center)
            .background(HubStyle.previewColor(\.sidebar, dark: dark))

            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(HubStyle.previewColor(\.ink, dark: dark).opacity(0.65))
                    .frame(width: 18, height: 3)
                Capsule().fill(HubStyle.previewColor(\.muted, dark: dark).opacity(0.45))
                    .frame(height: 3)
                    .padding(.trailing, 20)
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HubStyle.previewColor(\.canvas, dark: dark))
        }
    }

    private func toolStatus(_ title: String, subtitle: String, symbol: String, executable: String, activePath: String) -> some View {
        let available = FileManager.default.isExecutableFile(atPath: activePath)
        let isBuiltIn = activePath == ADBClient.bundledTool(executable)
        let status = available ? (isBuiltIn ? l10n.text("内置 · 使用中") : l10n.text("外部工具 · 使用中")) : l10n.text("当前工具不可用")

        return HStack(spacing: 12) {
            settingsIcon(symbol)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(HubStyle.muted)
            }
            Spacer()
            Label(status, systemImage: available ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(available ? HubStyle.green : HubStyle.ink)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func settingsIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14))
            .foregroundStyle(HubStyle.accent)
            .frame(width: 32, height: 32)
            .background(HubStyle.canvas.opacity(0.82), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityHidden(true)
    }
}

@MainActor
private struct AdvancedToolSettings: View {
    @Environment(\.l10n) private var l10n
    private enum Tool: Hashable { case adb, scrcpy }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: HubModel
    @Binding var adbPath: String
    @Binding var scrcpyPath: String
    @State private var saved = false
    @State private var editingPath: Tool?
    @FocusState private var focusedPath: Tool?

    private var toolsLocked: Bool { model.busy || model.mirroring }
    private var hasChanges: Bool { adbPath != model.adbPath || scrcpyPath != model.scrcpyPath }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(HubStyle.accent).accessibilityHidden(true)
                Text(l10n.text("高级设置")).font(.system(size: 18, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(l10n.text("关闭")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(HubStyle.workspaceTint, in: RoundedRectangle(cornerRadius: 10))
            advancedTools
        }
        .padding(HubStyle.workspaceInset)
        .frame(width: 520)
        .foregroundStyle(HubStyle.ink)
        .tint(HubStyle.accent)
        .background(HubStyle.canvas)
        .onChange(of: adbPath) { _ in saved = false }
        .onChange(of: scrcpyPath) { _ in saved = false }
        .onChange(of: focusedPath) { [previous = focusedPath] value in
            if value == nil, editingPath == previous { editingPath = nil }
        }
    }

    private var advancedTools: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                pathEditor("ADB", kind: .adb, path: $adbPath)
                Divider().overlay(HubStyle.line)
                pathEditor("scrcpy", kind: .scrcpy, path: $scrcpyPath)
            }
            .padding(16)
            .background(HubStyle.workspaceTint, in: RoundedRectangle(cornerRadius: 10))
            Divider().overlay(HubStyle.line)
            HStack(spacing: 8) {
                if toolsLocked {
                    Text(l10n.text("请先结束当前操作或投屏"))
                        .foregroundStyle(HubStyle.muted)
                } else if saved {
                    Label(l10n.text("工具路径已保存"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(HubStyle.muted)
                }
                Spacer()
                if let bundledADB = ADBClient.bundledTool("adb"),
                   let bundledScrcpy = ADBClient.bundledTool("scrcpy"),
                   adbPath != bundledADB || scrcpyPath != bundledScrcpy {
                    Button(l10n.text("使用内置路径")) {
                        editingPath = nil
                        adbPath = bundledADB
                        scrcpyPath = bundledScrcpy
                    }
                    .disabled(toolsLocked)
                }
                ToolbarAction(title: l10n.text("保存工具路径"), symbol: "checkmark", prominent: hasChanges) {
                    guard !toolsLocked, hasChanges else { return }
                    editingPath = nil
                    model.adbPath = adbPath
                    model.scrcpyPath = scrcpyPath
                    model.saveTools()
                    saved = true
                }
                .disabled(toolsLocked || !hasChanges)
            }
            .font(.system(size: 11))
        }
    }

    private func pathEditor(_ title: String, kind: Tool, path: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l10n.text("{1} 路径", title)).font(.system(size: 11, weight: .medium))
            HStack(spacing: 8) {
                Group {
                    if editingPath == kind {
                        TextField(l10n.text("可执行文件路径"), text: path)
                            .accessibilityLabel(l10n.text("{1} 路径", title))
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedPath, equals: kind)
                            .onAppear {
                                DispatchQueue.main.async {
                                    if editingPath == kind { focusedPath = kind }
                                }
                            }
                            .onSubmit { editingPath = nil }
                    } else {
                        Button {
                            editingPath = kind
                        } label: {
                            Text(path.wrappedValue.isEmpty ? l10n.text("可执行文件路径") : path.wrappedValue)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(path.wrappedValue.isEmpty ? HubStyle.muted : HubStyle.ink)
                                .padding(.horizontal, 7)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                                .background(HubStyle.canvas, in: RoundedRectangle(cornerRadius: 6))
                                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(HubStyle.line) }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(l10n.text("编辑 {1} 路径", title))
                        .accessibilityValue(path.wrappedValue)
                        .help(path.wrappedValue)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 24)
                Button(l10n.text("选择…")) {
                    editingPath = nil
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url {
                        path.wrappedValue = url.path
                    }
                }
                .accessibilityLabel(l10n.text("选择 {1} 路径", title))
            }
            .controlSize(.small)
        }
        .disabled(toolsLocked)
    }
}
