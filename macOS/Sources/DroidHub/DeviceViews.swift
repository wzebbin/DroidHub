import SwiftUI
import ImageIO
import DroidHubCore

struct DeviceLibraryView: View {
    @Environment(\.l10n) private var l10n
    @EnvironmentObject private var model: HubModel
    @Binding var showsDetails: Bool
    let connect: (DeviceConnectionEntry) -> Void

    private var info: AndroidDeviceInfo? { model.deviceInfoState.info }
    private var charge: Double? { info?.battery?.chargeFraction }
    private let detailColumnSpacing: CGFloat = 24
    private let minimumDetailColumnWidth: CGFloat = 320
    private let detailScrollGutter: CGFloat = 10

    var body: some View {
        Group {
            if let device = model.selectedDevice, device.isOnline {
                GeometryReader { geometry in
                    VStack(alignment: .leading, spacing: 14) {
                        header(device)
                        if info == nil {
                            initialReadStatus
                        } else {
                            overview
                            if model.deviceInfoState.failed {
                                WorkspaceNotice(message: l10n.text("刷新失败，仍显示上次读取的信息。"), isError: true)
                            }
                        }
                        if model.mirrorWindowReady { mirrorControls }
                        if info != nil { detailsToggle }
                        if (info != nil && showsDetails) || model.capturingScreenshot || model.screenshotURL != nil {
                            scrollableDetails
                        }
                    }
                    .frame(maxWidth: 820, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, geometry.size.height < 500 ? 16 : 24)
                    .frame(maxWidth: .infinity)
                }
            } else {
                LibraryStateView(symbol: "iphone", title: disconnectedTitle, detail: disconnectedDetail) {
                    HStack(spacing: 10) {
                        ToolbarAction(title: l10n.text("USB 连接"), symbol: "cable.connector", prominent: true) {
                            connect(.usb)
                        }
                        ToolbarAction(title: l10n.text("Wi‑Fi 连接"), symbol: "wifi") { connect(.wireless) }
                    }.disabled(model.busy)
                }
            }
        }
        .task(id: model.online ? model.deviceSession : nil) { model.loadDeviceInfo() }
    }

    private var scrollableDetails: some View {
        GeometryReader { region in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.capturingScreenshot {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(l10n.text("正在保存截图…"))
                        }
                        .font(.callout).foregroundStyle(HubStyle.muted)
                    } else if let screenshot = model.screenshotURL {
                        ScreenshotResultView(url: screenshot)
                    }
                    if info != nil && showsDetails {
                        detailGroups(availableWidth: max(0, region.size.width - detailScrollGutter))
                            .accessibilityLabel(l10n.text("设备详情参数"))
                    }
                }
                .padding(.trailing, detailScrollGutter)
                .padding(.bottom, 8)
            }
        }
    }

    private var detailsToggle: some View {
        ToolbarAction(title: showsDetails ? l10n.text("收起详情") : l10n.text("设备详情"),
                      symbol: showsDetails ? "chevron.up" : "chevron.down") {
            showsDetails.toggle()
        }
        .accessibilityValue(showsDetails ? l10n.text("已展开") : l10n.text("已收起"))
    }

    private var mirrorControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                mirrorStatus
                Spacer(minLength: 0)
                mirrorActions
            }
            VStack(alignment: .leading, spacing: 10) {
                mirrorStatus
                mirrorActions
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HubStyle.well, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(HubStyle.line))
    }

    private var mirrorStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(l10n.text("投屏中"), systemImage: "display")
                .font(.callout.weight(.semibold))
                .foregroundStyle(HubStyle.accent)
            Text(l10n.text("在投屏窗口按 F11 切换全屏"))
                .font(.caption)
                .foregroundStyle(HubStyle.muted)
        }
    }

    private var mirrorActions: some View {
        HStack(spacing: 8) {
            ToolbarAction(title: l10n.text("显示投屏窗口"), symbol: "macwindow", prominent: true) {
                model.showMirrorWindow()
            }
            ToolbarAction(title: l10n.text("截图"), symbol: "camera") { model.captureMirrorScreenshot() }
                .disabled(model.capturingScreenshot)
            ToolbarAction(title: l10n.text("结束投屏"), symbol: "stop.fill") { model.toggleMirroring() }
        }
    }

    private var disconnectedTitle: String {
        switch disconnectedState {
        case "unauthorized": return l10n.text("等待 USB 调试授权")
        case "offline": return l10n.text("手机已离线")
        default: return l10n.text("尚未连接手机")
        }
    }

    private var disconnectedDetail: String {
        switch disconnectedState {
        case "unauthorized": return l10n.text("请解锁手机，在弹窗中允许 USB 调试。")
        case "offline": return l10n.text("请检查 USB 线缆或手机的无线调试状态，然后重新连接。")
        default: return l10n.text("可用数据线连接手机，也可通过同一 Wi‑Fi 首次配对或重连。")
        }
    }

    private var disconnectedState: String? {
        if model.devices.contains(where: { !$0.isWireless && $0.state == "unauthorized" }) { return "unauthorized" }
        return model.selectedDevice?.state
    }

    @ViewBuilder private var initialReadStatus: some View {
        if model.deviceInfoState.failed {
            WorkspaceNotice(message: l10n.text("设备信息读取失败，请重试。"), isError: true)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text(l10n.text("正在读取设备信息…"))
            }
            .font(.callout).foregroundStyle(HubStyle.muted)
        }
    }

    @ViewBuilder
    private func detailGroups(availableWidth: CGFloat) -> some View {
        let columnWidth = (availableWidth - detailColumnSpacing) / 2
        if columnWidth < minimumDetailColumnWidth {
            VStack(alignment: .leading, spacing: 18) {
                systemCard
                capacityCard
                hardwareCard
                batteryCard
            }
        } else {
            Grid(alignment: .topLeading, horizontalSpacing: detailColumnSpacing, verticalSpacing: 18) {
                GridRow {
                    systemCard.frame(width: columnWidth)
                    capacityCard.frame(width: columnWidth)
                }
                GridRow {
                    hardwareCard.frame(width: columnWidth)
                    batteryCard.frame(width: columnWidth)
                }
            }
        }
    }

    private func header(_ device: AndroidDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone")
                .font(.system(size: 23))
                .foregroundStyle(HubStyle.accent)
                .frame(width: 44, height: 44)
                .background(HubStyle.workspaceTint, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(info?.marketName ?? info?.model ?? device.model)
                    .font(.system(size: 26, weight: .semibold))
                    .lineLimit(1)
                    .textSelection(.enabled)
                HStack(spacing: 7) {
                    Circle().fill(HubStyle.green).frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(device.isWireless ? l10n.text("Wi-Fi 已连接") : l10n.text("USB 已连接"))
                    if model.mirroringState == .starting || model.mirroringState == .stopping {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                        Text(model.mirroringState == .starting ? l10n.text("正在启动投屏…") : l10n.text("正在结束投屏…"))
                    } else if let updatedAt = model.deviceInfoState.updatedAt {
                        Text("·").accessibilityHidden(true)
                        if model.deviceInfoState.loading {
                            Text(l10n.text("正在刷新…"))
                        } else {
                            Text(l10n.text("更新于 ")) + Text(updatedAt, style: .time)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(HubStyle.muted)
                .lineLimit(1)
            }
            Spacer(minLength: 12)
            QuietIconButton(symbol: "arrow.clockwise",
                            help: info == nil && model.deviceInfoState.failed ? l10n.text("重试读取") : l10n.text("刷新设备信息")) {
                model.loadDeviceInfo(force: true)
            }
            .disabled(model.deviceInfoState.loading)
            if model.mirroringState == .idle || model.mirroringState == .starting {
                let starting = model.mirroringState == .starting
                ToolbarAction(title: starting ? l10n.text("取消启动") : l10n.text("开始投屏"),
                              symbol: starting ? "stop.fill" : "play.fill", prominent: !starting) {
                    model.toggleMirroring()
                }
            }
        }
    }

    private var overview: some View {
        HStack(alignment: .center, spacing: 0) {
            summary(l10n.text("电量"), symbol: "bolt", value: charge.map {
                $0.formatted(.percent.precision(.fractionLength(0)))
            }, note: batteryStatus)
            Divider().overlay(HubStyle.line).frame(height: 38)
            summary(l10n.text("剩余空间"), symbol: "internaldrive", value: info?.storage.map { bytes($0.availableBytes) },
                    note: info?.storage.map { l10n.text("总计 {1}", bytes($0.totalBytes)) })
            Divider().overlay(HubStyle.line).frame(height: 38)
            summary(l10n.text("Android 版本"), symbol: "gearshape", value: info?.androidVersion)
        }
        .padding(.vertical, 12)
        .background(HubStyle.well, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(HubStyle.line))
    }

    private func summary(_ title: String, symbol: String, value: String?, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(HubStyle.muted)
            Text(value ?? l10n.text("未提供"))
                .font(.system(size: value == nil ? 14 : 22, weight: .semibold))
                .foregroundStyle(value == nil ? HubStyle.muted : HubStyle.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(HubStyle.muted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    private var systemCard: some View {
        detailGroup(l10n.text("系统与连接")) {
            detail(l10n.text("API 级别"), info?.sdk)
            detail(l10n.text("系统版本号"), info?.build)
            detail(l10n.text("安全补丁"), info?.securityPatch)
            detail(model.selectedDevice?.isWireless == true ? l10n.text("ADB 连接标识") : l10n.text("USB 序列号"), model.onlineSerial)
        }
    }

    private var hardwareCard: some View {
        detailGroup(l10n.text("硬件与屏幕")) {
            detail(l10n.text("制造商"), info?.manufacturer)
            detail(l10n.text("型号"), info?.model)
            detail(l10n.text("设备代号"), info?.deviceCode)
            detail(l10n.text("处理器"), info?.processor)
            detail(l10n.text("处理器架构"), info?.architecture)
            detail(l10n.text("物理分辨率"), info?.screenSize.map { "\($0) px" })
            detail(l10n.text("系统报告密度"), info?.screenDensity.map { "\($0) dpi" })
        }
    }

    private var capacityCard: some View {
        detailGroup(l10n.text("存储与内存")) {
            let storage = info?.storage
            detail(l10n.text("内部存储已用"), storage.map { bytes($0.usedBytes) })
            if let storage {
                ProgressView(value: storage.usedFraction).tint(HubStyle.accent)
                    .accessibilityLabel(l10n.text("内部存储使用比例"))
                    .gridCellColumns(2)
                    .gridCellUnsizedAxes(.horizontal)
            }
            detail(l10n.text("内部存储总计"), storage.map { bytes($0.totalBytes) })
            Divider().gridCellColumns(2).gridCellUnsizedAxes(.horizontal)
            detail(l10n.text("内存可用"), info?.availableMemory.map(memorySize))
            detail(l10n.text("内存总计"), info?.totalMemory.map(memorySize))
        }
    }

    private var batteryCard: some View {
        detailGroup(l10n.text("电池")) {
            if let charge {
                ProgressView(value: charge).tint(HubStyle.green)
                    .accessibilityLabel(l10n.text("电池电量"))
                    .gridCellColumns(2)
                    .gridCellUnsizedAxes(.horizontal)
            }
            detail(l10n.text("电池温度"), info?.battery?.temperatureCelsius.map {
                "\($0.formatted(.number.precision(.fractionLength(1)))) °C"
            })
        }
    }

    private var batteryStatus: String? {
        switch info?.battery?.status {
        case .charging: return l10n.text("正在充电")
        case .discharging: return l10n.text("放电中")
        case .notCharging: return l10n.text("未充电")
        case .full: return l10n.text("已充满")
        case nil: return nil
        }
    }

    private func detailGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Divider().overlay(HubStyle.line)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6, content: content)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detail(_ title: String, _ value: String?) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(HubStyle.muted).fixedSize()
            if let value {
                Text(value).textSelection(.enabled)
            } else {
                Text(l10n.text("未提供")).foregroundStyle(HubStyle.muted)
            }
        }
    }

    private func bytes(_ count: Int64) -> String { count.formatted(.byteCount(style: .decimal)) }

    private func memorySize(_ count: Int64) -> String {
        let gibibytes = Double(count) / 1_073_741_824
        return "\(gibibytes.formatted(.number.precision(.fractionLength(0...1)))) GiB"
    }
}

private struct ScreenshotResultView: View {
    @Environment(\.l10n) private var l10n
    @EnvironmentObject private var model: HubModel
    let url: URL
    @State private var thumbnail: CGImage?
    @State private var copied = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(HubStyle.selection)
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1).resizable().scaledToFit()
                } else {
                    Image(systemName: "photo").foregroundStyle(HubStyle.muted)
                }
            }.frame(width: 78, height: 82).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(l10n.text("截图已保存")).font(.system(size: 12, weight: .semibold))
                Text(url.lastPathComponent).font(.caption).foregroundStyle(HubStyle.muted)
                    .lineLimit(1).truncationMode(.middle).help(url.path)
                HStack(spacing: 7) {
                    ToolbarAction(title: l10n.text("打开"), symbol: "arrow.up.right.square") { model.openMirrorScreenshot() }
                    ToolbarAction(title: copied ? l10n.text("已复制") : l10n.text("复制图片"), symbol: copied ? "checkmark" : "doc.on.doc") {
                        copied = model.copyMirrorScreenshot()
                    }
                    ToolbarAction(title: l10n.text("在 Finder 中显示"), symbol: "folder") { model.revealMirrorScreenshot() }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HubStyle.workspaceTint, in: RoundedRectangle(cornerRadius: 12))
        .task(id: url) {
            thumbnail = nil
            copied = false
            let image = await Self.readThumbnail(url)
            if !Task.isCancelled { thumbnail = image }
        }
    }

    private static func readThumbnail(_ url: URL) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 180
        ] as CFDictionary)
    }
}
