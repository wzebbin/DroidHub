import AppKit
import DroidHubCore
import SwiftUI
import UniformTypeIdentifiers

struct ApplicationLibraryView: View {
    @Environment(\.l10n) private var l10n
    @EnvironmentObject private var model: HubModel
    let connect: () -> Void
    let onReady: () -> Void
    @ObservedObject var applications: ApplicationLibraryState

    @Binding var query: String
    @Binding var showsSystem: Bool
    @AppStorage("applicationSort") private var sort = AndroidApplicationSort.name
    @State private var selection: String?
    @State private var uninstallRequest: UninstallRequest?
    @State private var decodedIcons = NSCache<NSData, NSImage>()

    private struct UninstallRequest {
        let package: String
        let user: Int
        let session: UUID
        let device: String
    }

    var body: some View {
        Group {
            if model.online {
                connected
            } else {
                LibraryStateView(symbol: "square.grid.2x2", title: l10n.text("连接手机以管理应用"),
                                  detail: l10n.text("连接后可以查看应用，以及安装和导出安装包。")) {
                    ToolbarAction(title: l10n.text("连接设备"), symbol: "link", prominent: true, action: connect)
                }
            }
        }
        .onAppear { if applications.applicationList != nil { onReady() } }
        .onChange(of: applications.applicationList != nil) { ready in
            if ready { onReady() }
        }
        .task(id: model.online ? model.deviceSession : nil) { await model.loadApplicationsWhenReady() }
        .onChange(of: model.deviceSession) { _ in
            selection = nil
            uninstallRequest = nil
        }
        .alert(l10n.text("卸载应用？"), isPresented: Binding(get: { uninstallRequest != nil }, set: {
            if !$0 { uninstallRequest = nil }
        }), presenting: uninstallRequest) { request in
            Button(l10n.text("取消"), role: .cancel) { }
            Button(l10n.text("卸载"), role: .destructive) {
                model.uninstallApplication(request.package, session: request.session, user: request.user)
            }
        } message: { request in
            Text(l10n.text("将从「{1}」的当前用户卸载 {2}，并删除该用户的应用数据。", request.device, request.package))
        }
    }

    private var connected: some View {
        let session = model.deviceSession
        let apps = applications.applicationList?.applications ?? []
        let filter = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = sort.ordered(apps.filter {
            (showsSystem || !$0.isSystem) && $0.matches(filter)
        })
        let selected = visible.first { $0.package == selection }
        let user = applications.applicationList?.user
        return VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                applicationToolbar(selected: selected, session: session, user: user, compact: false)
                    .frame(minWidth: 640)
                applicationToolbar(selected: selected, session: session, user: user, compact: true)
            }
            .padding(.horizontal, HubStyle.workspaceInset).frame(height: HubStyle.controlBarHeight)
            .background(HubStyle.workspaceTint)
            Divider().overlay(HubStyle.line)
            if applications.applicationList != nil {
                if let failure = applications.applicationListFailure {
                    WorkspaceNotice(message: l10n.text("无法刷新应用列表，仍显示上次读取的列表。{1}", failure), isError: true)
                        .padding(.horizontal, HubStyle.workspaceInset).padding(.top, 8)
                }
                if visible.isEmpty, !filter.isEmpty, applications.loadingApplicationDetails {
                    LibraryStateView(symbol: nil, title: l10n.text("正在读取应用名称…"),
                                      detail: l10n.text("名称读取后，搜索结果会自动更新。")) { EmptyView() }
                } else if visible.isEmpty {
                    LibraryStateView(symbol: "magnifyingglass", title: filter.isEmpty ? l10n.text("没有可显示的应用") : l10n.text("没有匹配的应用"),
                                      detail: emptyDetail(searching: !filter.isEmpty)) { EmptyView() }
                } else {
                    Table(visible, selection: $selection) {
                        TableColumn(l10n.text("应用")) { application in
                            HStack(spacing: 10) {
                                Group {
                                    if let data = application.iconPNG, let icon = decodedIcon(data) {
                                        Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
                                    } else {
                                        Image(systemName: "app").foregroundStyle(rowStyle(for: application))
                                    }
                                }
                                .frame(width: 24, height: 24)
                                .accessibilityHidden(true)
                                Text(application.displayName).lineLimit(1)
                                    .foregroundStyle(rowStyle(for: application, secondary: false))
                                    .help(application.displayName)
                            }
                        }.width(min: 145, ideal: 220)
                        TableColumn(l10n.text("应用包名")) { application in
                            Text(application.package).lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(rowStyle(for: application))
                                .help(application.package)
                        }
                        TableColumn(l10n.text("版本")) { application in
                            Text(application.version ?? "—").lineLimit(1)
                                .foregroundStyle(rowStyle(for: application))
                                .help(application.version ?? l10n.text("手机未提供版本"))
                        }.width(min: 58, ideal: 88, max: 160)
                        TableColumn(l10n.text("APK 大小")) { application in
                            Text(apkSize(application))
                                .lineLimit(1).monospacedDigit().foregroundStyle(rowStyle(for: application))
                                .help(l10n.text("已安装的 APK 文件大小，含分包"))
                        }.width(min: 70, ideal: 90, max: 120)
                        TableColumn(l10n.text("类型")) { application in
                            Text(application.isSystem ? l10n.text("系统应用") : l10n.text("第三方应用"))
                                .foregroundStyle(rowStyle(for: application))
                        }.width(min: 90, ideal: 110, max: 150)
                    }
                    .tableStyle(.inset(alternatesRowBackgrounds: false))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .contextMenu(forSelectionType: String.self) { rows in
                        if rows.count == 1, let package = rows.first,
                           let app = visible.first(where: { $0.package == package }),
                           let user {
                            Button {
                                model.launchApplication(package, session: session, user: user)
                            } label: {
                                Label(l10n.text("在手机上打开"), systemImage: "play")
                            }.disabled(model.busy || !applications.applicationListVerified || app.launcherComponent == nil)
                            Button {
                                model.exportApplication(package, session: session, user: user)
                            } label: {
                                Label(l10n.text("导出安装包…"), systemImage: "square.and.arrow.up")
                            }.disabled(model.busy || !applications.applicationListVerified)
                        }
                    }
                }
            } else if let failure = applications.applicationListFailure {
                LibraryStateView(symbol: "exclamationmark.circle", title: l10n.text("无法读取应用列表"), detail: failure, isError: true) {
                    ToolbarAction(title: l10n.text("重新加载"), symbol: "arrow.clockwise", prominent: true) {
                        model.refreshApplications()
                    }.disabled(model.busy)
                }
            } else if model.busy {
                LibraryStateView(symbol: nil, title: l10n.text("正在读取应用列表…")) { EmptyView() }
            } else {
                LibraryStateView(symbol: "square.grid.2x2", title: l10n.text("应用列表待刷新"), detail: l10n.text("刷新后查看手机上的应用。")) {
                    ToolbarAction(title: l10n.text("刷新"), symbol: "arrow.clockwise") { model.refreshApplications() }
                }
            }
            if let selected, let user {
                Divider().overlay(HubStyle.line)
                applicationDetails(selected, session: session, user: user)
            }
            Divider().overlay(HubStyle.line)
            HStack(spacing: 8) {
                Text(l10n.text("{1} 个应用", visible.count))
                Spacer()
                if applications.loadingApplicationDetails {
                    ProgressView().controlSize(.mini)
                    Text(l10n.text("读取应用详情…"))
                } else if applications.applicationDetailsUnavailable {
                    Label(l10n.text("应用名称暂不可用"), systemImage: "info.circle")
                        .help(l10n.text("仍可按包名搜索"))
                }
            }
            .font(.system(size: 11)).foregroundStyle(HubStyle.muted)
            .padding(.horizontal, HubStyle.workspaceInset).frame(height: 28)
        }
    }

    private func applicationToolbar(selected: AndroidApplication?, session: UUID, user: Int?, compact: Bool) -> some View {
        let canAct = !model.busy && applications.applicationListVerified
        func launch() {
            guard let selected, let user else { return }
            model.launchApplication(selected.package, session: session, user: user)
        }
        func uninstall() {
            guard let selected, !selected.isSystem, let user else { return }
            uninstallRequest = UninstallRequest(package: selected.package, user: user, session: session,
                                                device: model.selectedDevice?.model ?? l10n.text("手机"))
        }
        return HStack(spacing: compact ? 8 : 12) {
            LibrarySearchField(placeholder: l10n.text("搜索应用名称或包名"), query: $query, width: compact ? 152 : 170)
            Menu {
                ForEach(AndroidApplicationSort.allCases, id: \.self) { order in
                    Button {
                        sort = order
                    } label: {
                        if sort == order {
                            Label(sortTitle(order), systemImage: "checkmark")
                        } else {
                            Text(sortTitle(order))
                        }
                    }
                }
            } label: {
                if compact {
                    Label(l10n.text("应用排序"), systemImage: "arrow.up.arrow.down").labelStyle(.iconOnly)
                } else {
                    Label(sortTitle(sort), systemImage: "arrow.up.arrow.down").labelStyle(.titleAndIcon)
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help(l10n.text("应用排序：{1}", sortTitle(sort))).accessibilityLabel(l10n.text("应用排序"))
            Spacer(minLength: 0)
            QuietIconButton(symbol: "arrow.clockwise", help: l10n.text("刷新应用列表")) { model.refreshApplications() }
                .disabled(model.busy)
            if compact {
                Menu {
                    Toggle(l10n.text("显示系统应用"), isOn: $showsSystem)
                    Divider()
                    Button(l10n.text("在手机上打开"), action: launch)
                        .disabled(!canAct || selected?.launcherComponent == nil)
                    Button(l10n.text("卸载"), action: uninstall)
                        .disabled(!canAct || selected?.isSystem != false)
                } label: {
                    Label(l10n.text("更多应用操作"), systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton).fixedSize().help(l10n.text("更多应用操作"))
            } else {
                Toggle(l10n.text("显示系统应用"), isOn: $showsSystem).toggleStyle(.checkbox).fixedSize()
                ToolbarAction(title: l10n.text("在手机上打开"), symbol: "play.fill", action: launch)
                    .fixedSize().disabled(!canAct || selected?.launcherComponent == nil)
                ToolbarAction(title: l10n.text("卸载"), symbol: "trash", action: uninstall)
                    .fixedSize().disabled(!canAct || selected?.isSystem != false)
            }
            ToolbarAction(title: l10n.text("安装 APK…"), symbol: "square.and.arrow.down", prominent: true, action: selectAPK)
                .fixedSize().disabled(!canAct)
        }
    }

    private func sortTitle(_ order: AndroidApplicationSort) -> String {
        switch order {
        case .name: l10n.text("按应用名称")
        case .recentInstall: l10n.text("最近安装")
        case .recentUpdate: l10n.text("最近更新")
        case .largestAPK: l10n.text("APK 大小")
        }
    }

    private func rowStyle(for application: AndroidApplication, secondary: Bool = true) -> AnyShapeStyle {
        if application.package == selection {
            return AnyShapeStyle(ForegroundStyle())
        }
        return AnyShapeStyle(secondary ? HubStyle.muted : HubStyle.ink)
    }

    private func decodedIcon(_ data: Data) -> NSImage? {
        let key = data as NSData
        if let icon = decodedIcons.object(forKey: key) { return icon }
        guard let icon = NSImage(data: data) else { return nil }
        decodedIcons.countLimit = 256
        decodedIcons.setObject(icon, forKey: key)
        return icon
    }

    private func applicationDetails(_ app: AndroidApplication, session: UUID, user: Int) -> some View {
        let details = app.details
        let fields: [(String, String)] = [
            (l10n.text("包名"), app.package),
            (l10n.text("版本"), app.version ?? "—"),
            (l10n.text("版本代码"), details?.versionCode.map(String.init) ?? "—"),
            (l10n.text("APK 大小"), apkSize(app)),
            (l10n.text("分包数量"), details?.splitCount.map { $0 == 0 ? l10n.text("单 APK") : l10n.text("{1} 个分包", $0) } ?? "—"),
            (l10n.text("最低 Android"), details?.minimumSDK.map { "API \($0)" } ?? "—"),
            (l10n.text("目标 Android"), details?.targetSDK.map { "API \($0)" } ?? "—"),
            (l10n.text("首次安装"), dateText(details?.installedAt)),
            (l10n.text("最近更新"), dateText(details?.updatedAt))
        ]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(app.displayName).font(.system(size: 12, weight: .semibold))
                Spacer()
                QuietIconButton(symbol: "document.on.document", help: l10n.text("复制应用详情")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        ([app.displayName] + fields.map { "\($0.0)：\($0.1)" }).joined(separator: "\n"),
                        forType: .string
                    )
                }
                ToolbarAction(title: l10n.text("导出安装包…"), symbol: "square.and.arrow.up") {
                    model.exportApplication(app.package, session: session, user: user)
                }.disabled(model.busy || !applications.applicationListVerified)
            }
            Text(app.package).font(.callout).foregroundStyle(HubStyle.muted).textSelection(.enabled)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                ForEach(1...4, id: \.self) { index in
                    GridRow {
                        Text(fields[index].0).foregroundStyle(HubStyle.muted)
                        Text(fields[index].1).textSelection(.enabled)
                        Text(fields[index + 4].0).foregroundStyle(HubStyle.muted).padding(.leading, 12)
                        Text(fields[index + 4].1).textSelection(.enabled)
                    }
                }
            }.font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, HubStyle.workspaceInset).padding(.vertical, 12)
        .background(HubStyle.workspaceTint)
    }

    private func dateText(_ date: Date?) -> String {
        date?.formatted(date: .numeric, time: .shortened) ?? "—"
    }

    private func apkSize(_ app: AndroidApplication) -> String {
        app.apkBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
    }

    private func emptyDetail(searching: Bool) -> String {
        if !searching { return l10n.text("可以安装 APK 或切换系统应用的显示范围。") }
        if applications.applicationDetailsUnavailable { return l10n.text("应用名称暂不可用，请试试包名。") }
        return l10n.text("试试其他应用名称或包名。")
    }

    private func selectAPK() {
        guard let user = applications.applicationList?.user else { return }
        let session = model.deviceSession
        let picker = NSOpenPanel()
        picker.title = l10n.text("选择要安装的 APK")
        picker.prompt = l10n.text("安装")
        picker.message = l10n.text("安装到「{1}」的当前用户。已安装的同一应用会更新。", model.selectedDevice?.model ?? l10n.text("手机"))
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        if let apk = UTType(filenameExtension: "apk") { picker.allowedContentTypes = [apk] }
        guard picker.runModal() == .OK, let url = picker.url else { return }
        model.installApplication(url, session: session, user: user)
    }
}
