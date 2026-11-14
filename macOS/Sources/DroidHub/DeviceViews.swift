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
    private var showsCaptureFeedback: Bool {
        model.capturingScreenshot || model.screenshotURL != nil || model.isSavingRecording || model.recordingURL != nil
    }
    private let detailColumnSpacing: CGFloat = 24
    private let minimumDetailColumnWidth: CGFloat = 320
    private let detailScrollGutter: CGFloat = 10

    var body: some View {
        VStack(spacing: 0) {
            if showsCaptureFeedback && !model.online && model.initialDeviceDetection != .checking {
                captureFeedback
                    .padding(.horizontal, 28)
                    .padding(.top, 16)
                    .frame(maxWidth: 876)
            }
            deviceContent
        }
    }

    @ViewBuilder private var deviceContent: some View {
        if model.online || model.initialDeviceDetection == .checking {
            deviceOverview(model.online ? model.selectedDevice : nil)
        } else if case .failed(let message) = model.initialDeviceDetection {
            LibraryStateView(symbol: "exclamationmark.circle", title: l10n.text("无法检测设备"),
                             detail: message, isError: true) {
                if model.adbPath.isEmpty {
                    ToolbarAction(title: l10n.text("设置"), symbol: "gearshape", prominent: true) { openToolSettings() }
                } else {
                    ToolbarAction(title: l10n.text("重新检测"), symbol: "arrow.clockwise", prominent: true) {
                        Task { await model.retryInitialDeviceDetection() }
                    }
                }
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

    private var captureFeedback: some View {
        VStack(spacing: 8) {
            if model.capturingScreenshot || model.screenshotURL != nil {
                CaptureResultCard(kind: .screenshot, url: model.capturingScreenshot ? nil : model.screenshotURL)
            }
            if model.isSavingRecording || model.recordingURL != nil {
                CaptureResultCard(kind: .recording, url: model.isSavingRecording ? nil : model.recordingURL)
            }
        }
    }

    private func deviceOverview(_ device: AndroidDevice?) -> some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 14) {
                header(device)
                overview
                if model.deviceInfoState.failed {
                    WorkspaceNotice(message: info == nil
                                    ? l10n.text("设备信息读取失败，请重试。")
                                    : l10n.text("刷新失败，仍显示上次读取的信息。"), isError: true)
                }
                if info != nil { detailsToggle }
                if info != nil && showsDetails {
                    scrollableDetails
                }
            }
            .frame(maxWidth: 820, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 28)
            .padding(.vertical, geometry.size.height < 500 ? 16 : 24)
            .frame(maxWidth: .infinity)
        }
    }

    private var scrollableDetails: some View {
        GeometryReader { region in
            ScrollView {
                detailGroups(availableWidth: max(0, region.size.width - detailScrollGutter))
                    .accessibilityLabel(l10n.text("设备详情参数"))
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

    private func header(_ device: AndroidDevice?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                deviceIdentity(device)
                Spacer(minLength: 6)
                QuietIconButton(symbol: "arrow.clockwise",
                                help: info == nil && model.deviceInfoState.failed ? l10n.text("重试读取") : l10n.text("刷新设备信息")) {
                    model.loadDeviceInfo(force: true)
                }
                .disabled(device == nil || model.deviceInfoState.loading)
            }
            HStack(spacing: 8) {
                if model.mirrorWindowReady {
                    ToolbarAction(title: l10n.text("显示投屏窗口"), symbol: "macwindow", prominent: true) {
                        model.showMirrorWindow()
                    }
                } else {
                    let starting = model.mirroringState == .starting
                    ToolbarAction(title: starting ? l10n.text("取消启动") : l10n.text("开始投屏"),
                                  symbol: starting ? "stop.fill" : "display",
                                  prominent: !starting, height: 30) {
                        model.toggleMirroring()
                    }
                    .disabled(device == nil || model.mirroringState == .stopping)
                }
                ToolbarAction(title: l10n.text("截图"), symbol: "camera") { model.captureDeviceScreenshot() }
                    .disabled(device == nil || model.capturingScreenshot)
                ToolbarAction(title: l10n.text(model.isRecording ? "停止录屏" : "录屏"),
                              symbol: model.isRecording ? "stop.circle.fill" : "record.circle") {
                    if model.isRecording { model.stopScreenRecording() }
                    else { model.startScreenRecording() }
                }
                .disabled(device == nil || model.isSavingRecording)
                if let startedAt = model.recordingStartedAt {
                    RecordingTimer(startedAt: startedAt)
                } else if model.isRecording {
                    ProgressView()
                        .controlSize(.small)
                        .help(l10n.text("正在启动录屏…"))
                        .accessibilityLabel(l10n.text("正在启动录屏…"))
                }
                if model.mirrorWindowReady {
                    ToolbarAction(title: l10n.text("结束投屏"), symbol: "stop.fill") { model.toggleMirroring() }
                    Text(l10n.text("在投屏窗口按 F11 切换全屏"))
                        .font(.caption).foregroundStyle(HubStyle.muted).lineLimit(1)
                        .help(l10n.text("在投屏窗口按 F11 切换全屏"))
                        .padding(.leading, 4)
                }
            }
            .frame(height: 30)
            if showsCaptureFeedback {
                captureFeedback
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HubStyle.deviceSurface, in: RoundedRectangle(cornerRadius: 13))
    }

    private func deviceIdentity(_ device: AndroidDevice?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone")
                .font(.system(size: 23))
                .foregroundStyle(HubStyle.accent)
                .frame(width: 49, height: 49)
                .background(HubStyle.canvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(info?.marketName ?? info?.model ?? device?.model ?? l10n.text("正在检测设备…"))
                    .font(.system(size: 26, weight: .semibold))
                    .lineLimit(1)
                    .textSelection(.enabled)
                HStack(spacing: 7) {
                    if let device {
                        Circle().fill(HubStyle.green).frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(device.isWireless ? l10n.text("Wi-Fi 已连接") : l10n.text("USB 已连接"))
                    }
                    if model.mirroringState == .starting || model.mirroringState == .stopping {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                        Text(model.mirroringState == .starting ? l10n.text("正在启动投屏…") : l10n.text("正在结束投屏…"))
                    } else if model.mirrorWindowReady {
                        Text("·").accessibilityHidden(true)
                        Text(l10n.text("投屏中"))
                            .foregroundStyle(HubStyle.accent)
                    } else if let updatedAt = model.deviceInfoState.updatedAt {
                        Text("·").accessibilityHidden(true)
                        if model.deviceInfoState.loading {
                            Text(l10n.text("正在刷新…"))
                        } else {
                            Text(l10n.text("更新于 ")) + Text(updatedAt, style: .time)
                        }
                    } else if !model.deviceInfoState.failed {
                        if device != nil { Text("·").accessibilityHidden(true) }
                        ProgressView().controlSize(.mini).accessibilityHidden(true)
                        Text(device == nil ? l10n.text("正在检查 USB 和 Wi‑Fi 连接") : l10n.text("正在读取设备信息…"))
                    }
                }
                .font(.caption)
                .foregroundStyle(HubStyle.muted)
                .lineLimit(1)
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
        .padding(.vertical, 8)
    }

    private func summary(_ title: String, symbol: String, value: String?, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(HubStyle.muted)
            Text(value ?? (info == nil ? "—" : l10n.text("未提供")))
                .font(.system(size: value == nil && info != nil ? 14 : 22, weight: .semibold))
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

private struct RecordingTimer: View {
    @Environment(\.l10n) private var l10n
    let startedAt: ContinuousClock.Instant

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let seconds = max(0, startedAt.duration(to: .now).components.seconds)
            let time = seconds < 3600
                ? String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
                : String(format: "%lld:%02lld:%02lld", seconds / 3600, seconds / 60 % 60, seconds % 60)
            HStack(spacing: 5) {
                Circle().fill(HubStyle.error).frame(width: 6, height: 6)
                Text(time).font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(l10n.text("录屏时长"))
            .accessibilityValue(time)
        }
    }
}

private struct CaptureResultCard: View {
    enum Kind {
        case screenshot, recording

        var savingTitle: String { self == .screenshot ? "正在保存截图…" : "正在保存录屏…" }
        var savedTitle: String { self == .screenshot ? "截图已保存" : "录屏已保存" }
        var symbol: String { self == .screenshot ? "photo" : "film" }
    }

    @Environment(\.l10n) private var l10n
    @EnvironmentObject private var model: HubModel
    let kind: Kind
    let url: URL?
    @State private var thumbnail: CGImage?
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(HubStyle.selection)
                if url == nil {
                    ProgressView().controlSize(.small)
                } else if let thumbnail {
                    Image(decorative: thumbnail, scale: 1).resizable().scaledToFit()
                } else {
                    Image(systemName: kind.symbol).foregroundStyle(HubStyle.muted)
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(l10n.text(url == nil ? kind.savingTitle : kind.savedTitle))
                    .font(.system(size: 12, weight: .semibold))
                if let url {
                    Text(url.lastPathComponent).font(.caption).foregroundStyle(HubStyle.muted)
                        .lineLimit(1).truncationMode(.middle).help(url.path)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(-1)

            if let url {
                actions(for: url)
                    .fixedSize()
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HubStyle.workspaceTint, in: RoundedRectangle(cornerRadius: 8))
        .task(id: url) {
            thumbnail = nil
            copied = false
            guard kind == .screenshot, let url else { return }
            let image = await Self.readThumbnail(url)
            if !Task.isCancelled { thumbnail = image }
        }
    }

    private func actions(for url: URL) -> some View {
        HStack(spacing: 4) {
            ToolbarAction(title: l10n.text("打开"), symbol: kind == .screenshot ? "arrow.up.right.square" : "play") {
                if kind == .screenshot {
                    model.openDeviceScreenshot()
                } else if !NSWorkspace.shared.open(url) {
                    model.error = l10n.text("无法打开录屏。")
                }
            }
            if kind == .screenshot {
                ToolbarAction(title: copied ? l10n.text("已复制") : l10n.text("复制图片"),
                              symbol: copied ? "checkmark" : "doc.on.doc") {
                    copied = model.copyDeviceScreenshot()
                }
            }
            Menu {
                Button {
                    if kind == .screenshot {
                        model.revealDeviceScreenshot()
                    } else {
                        model.revealFileInFinder(url, failureMessage: l10n.text("无法在 Finder 中显示录屏"))
                    }
                } label: {
                    Label(l10n.text("在 Finder 中显示"), systemImage: "folder")
                }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(HubStyle.muted)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help(l10n.text("更多操作"))
            .accessibilityLabel(l10n.text("更多操作"))

            QuietIconButton(symbol: "xmark", help: l10n.text("关闭"), height: 27) {
                switch kind {
                case .screenshot: model.dismissScreenshotResult()
                case .recording: model.dismissRecordingResult()
                }
            }
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
