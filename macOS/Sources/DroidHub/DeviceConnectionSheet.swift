import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import DroidHubCore

enum DeviceConnectionEntry: String, Identifiable {
    case all, usb, wireless

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return L10n.text("连接设备")
        case .usb: return L10n.text("USB 连接")
        case .wireless: return L10n.text("Wi‑Fi 连接")
        }
    }
}

struct DeviceConnectionSheet: View {
    @Environment(\.l10n) private var l10n
    let entry: DeviceConnectionEntry
    private enum Method: String, CaseIterable, Identifiable {
        case code = "配对码", qr = "扫码配对", address = "连接地址"
        var id: Self { self }
    }

    @EnvironmentObject private var model: HubModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("recentWirelessDevice") private var recentData = Data()
    @State private var addingDevice = false
    @State private var showsConnectionAddress = false
    @State private var method: Method = .qr
    @State private var pairingAddress = ""
    @State private var connectionAddress = ""
    @State private var code = ""
    @State private var services: [ADBWirelessService] = []
    @State private var discoveryError = false
    @State private var discoveryStarted = false
    @State private var discoveryID = UUID()
    @State private var status: Status?
    @State private var failed = false
    @State private var failure: ADBWirelessFailure?
    @State private var phase: ConnectionPhase = .discovery
    @State private var addressSource: AddressSource?
    @State private var lastDiagnostic: ConnectionDiagnostic?
    @State private var expectedManualFingerprint: String?
    @State private var activeFingerprint: String?
    @State private var copyingDiagnostic = false
    @State private var copiedDiagnostic = false
    @State private var qrImage: NSImage?
    @State private var operation: Task<Void, Never>?
    @State private var attempt = UUID()

    private enum ConnectionPhase: String {
        case discovery = "发现设备"
        case pairing = "配对"
        case connecting = "连接"
        case identity = "核对设备身份"
        case connected = "已连接"
    }

    private enum AddressSource: String {
        case discovered = "局域网发现"
        case usb = "已授权的 USB"
        case previous = "上次地址"
        case manual = "手动输入"
    }

    private enum Status {
        case message(String)
        case connected(String)
        case failure(String)

        func text(_ l10n: L10n) -> String {
            switch self {
            case .message(let key): return l10n.text(key)
            case .connected(let name): return l10n.text("{1} 已通过 Wi‑Fi 连接。", name)
            case .failure(let diagnostic): return l10n.diagnostic(diagnostic)
            }
        }
    }

    private struct ConnectionDiagnostic {
        let phase: ConnectionPhase
        let source: AddressSource?
        let result: String
    }

    private struct RecentDevice: Codable {
        let model: String
        let address: String?
        let serviceSerial: String?
        let fingerprint: String?

        func matches(_ device: AndroidDevice) -> Bool {
            Self.normalize(device.serial) == serviceSerial || (address != nil && address == device.serial)
        }

        static func normalize(_ serial: String) -> String {
            serial.hasSuffix(".local") ? String(serial.dropLast(6)) : serial
        }
    }

    private var recent: RecentDevice? { try? JSONDecoder().decode(RecentDevice.self, from: recentData) }
    private var nearby: [ADBWirelessService] { services.filter { $0.kind == .connection } }
    private var readyForAction: Bool { operation == nil && !model.busy && !model.adbPath.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if addingDevice {
                    QuietIconButton(symbol: "chevron.left", help: l10n.text("返回设备列表"), action: returnToDevices)
                        .disabled(operation != nil)
                } else {
                    Image(systemName: "cable.connector")
                        .font(.system(size: 17))
                        .foregroundStyle(HubStyle.accent)
                        .accessibilityHidden(true)
                }
                Text(addingDevice ? l10n.text("Wi‑Fi 配对与连接") : entry.title).font(.system(size: 20, weight: .semibold))
                Spacer()
                if !addingDevice {
                    QuietIconButton(symbol: "arrow.clockwise", help: entry == .usb ? l10n.text("刷新 USB 设备") : l10n.text("刷新设备与无线发现")) {
                        discoveryID = UUID()
                        Task { await model.refreshDevices() }
                    }.disabled(operation != nil)
                }
            }.frame(minHeight: 28)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(HubStyle.deviceSurface, in: RoundedRectangle(cornerRadius: 10))
            Group {
                if model.adbPath.isEmpty {
                    WorkspaceNotice(message: l10n.text("找不到 ADB。请重新解压完整的 DroidHub 安装包，或在「设置 → 高级设置」中选择可用的 ADB。"), isError: true)
                } else if addingDevice {
                    addDeviceForm
                        .padding(14)
                        .background(HubStyle.well, in: RoundedRectangle(cornerRadius: 10))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView {
                        deviceList
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if let status {
                WorkspaceNotice(message: failure?.errorDescription ?? status.text(l10n), isError: failed)
                if failure?.needsConnectionAddress == true {
                    Button(l10n.text("输入当前连接地址"), action: showAddressRecovery)
                } else if failure == .networkUnavailable, #available(macOS 15, *) {
                    localNetworkSettings
                } else if failure == .unauthorized {
                    Button(l10n.text("打开配对方式")) {
                        expectedManualFingerprint = nil
                        changeMode()
                        addingDevice = true
                        method = .qr
                    }
                }
            }
            Divider().overlay(HubStyle.line)
            HStack(spacing: 10) {
                if operation != nil {
                    ProgressView().controlSize(.small)
                    Button(l10n.text("取消操作"), action: cancel)
                } else {
                    Button(copiedDiagnostic ? l10n.text("诊断信息已复制") : l10n.text("复制诊断信息"), action: copyDiagnostic)
                        .disabled(copyingDiagnostic)
                        .help(l10n.text("包含版本、连接阶段和设备数量。省略地址、配对码、序列号及文件名。"))
                }
                Spacer()
                Button(l10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
                if addingDevice, method != .qr {
                    ToolbarAction(title: method == .code ? l10n.text("配对并连接") : l10n.text("连接"),
                                  symbol: "link", prominent: true, action: start)
                        .disabled(!canStart)
                } else if !addingDevice, entry != .usb {
                    ToolbarAction(title: l10n.text("配对新设备"), symbol: "plus", prominent: true) {
                        expectedManualFingerprint = nil
                        method = .qr
                        addingDevice = true
                        changeMode()
                    }.disabled(!readyForAction)
                }
            }
        }
        .padding(HubStyle.workspaceInset).frame(width: 520, height: addingDevice ? nil : 440)
        .foregroundStyle(HubStyle.ink)
        .onChange(of: model.adbPath) { _ in changeMode() }
        .onDisappear { cancel() }
        .task(id: DiscoveryRequest(path: model.adbPath, id: discoveryID)) {
            services = []; discoveryError = false; discoveryStarted = false
            guard entry != .usb, !model.adbPath.isEmpty else { return }
            while !Task.isCancelled {
                if operation == nil {
                    do {
                        let found = try await model.adb.wirelessServices()
                        try Task.checkCancellation()
                        services = found; discoveryError = false; discoveryStarted = true
                        if let device = model.selectedDevice, device.isOnline, device.isWireless {
                            let service = service(for: device)
                            let fingerprint = currentFingerprint(for: device)
                            if recent?.matches(device) != true || (service != nil && recent?.serviceSerial != service?.serial)
                                || (fingerprint != nil && recent?.fingerprint != fingerprint) {
                                remember(device, endpoint: ADBEndpoint(device.serial), service: service, fingerprint: fingerprint)
                            }
                        }
                    } catch {
                        if Task.isCancelled { return }
                        services = []; discoveryError = true; discoveryStarted = true
                    }
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private struct DiscoveryRequest: Equatable {
        let path: String
        let id: UUID
    }

    private func service(for device: AndroidDevice) -> ADBWirelessService? {
        nearby.first { $0.serial == RecentDevice.normalize(device.serial) || $0.endpoint == ADBEndpoint(device.serial) }
    }

    private var deviceList: some View {
        let devices = model.devices.filter { device in
            if device.isWireless { return entry != .usb && device.isOnline }
            return entry != .wireless
        }
        let saved = entry == .usb ? nil : recent
        let savedEndpoint = saved?.address.flatMap(ADBEndpoint.init)
        let savedService = ADBWirelessService.reconnectionService(in: nearby, serial: saved?.serviceSerial,
                                                                   previous: savedEndpoint,
                                                                   canVerifyIdentity: saved?.fingerprint != nil)
        let savedIsOnline = devices.contains { device in
            guard device.isWireless else { return false }
            return saved?.matches(device) == true || saved?.fingerprint.map { currentFingerprint(for: device) == $0 } == true
        }
        let offersReconnect = saved != nil && !savedIsOnline
        let discovered = nearby.filter { service in
            !devices.contains { self.service(for: $0) == service } && !(offersReconnect && service == savedService)
        }
        return VStack(alignment: .leading, spacing: 10) {
            if !devices.isEmpty || offersReconnect || !discovered.isEmpty {
                VStack(spacing: 1) {
                    ForEach(devices) { device in
                        deviceRow(name: device.model, detail: detail(for: device), wireless: device.isWireless) {
                            if model.selectedSerial == device.serial && device.isOnline {
                                Label(l10n.text("当前设备"), systemImage: "checkmark.circle.fill").foregroundStyle(HubStyle.green)
                            } else if device.isOnline {
                                Button(l10n.text("选择")) {
                                    model.selectedSerial = device.serial
                                    if device.isWireless { remember(device, endpoint: ADBEndpoint(device.serial), service: service(for: device)) }
                                }.disabled(!readyForAction)
                            }
                        }
                    }
                    if offersReconnect, let saved {
                        let detail = savedService.map { l10n.text("Wi‑Fi · 已发现 {1}", $0.endpoint) } ?? l10n.text("Wi‑Fi · 最近连接")
                        deviceRow(name: saved.model, detail: detail, wireless: true) {
                            Button(l10n.text("重连")) { reconnect(saved) }.disabled(!readyForAction)
                        }
                    }
                    ForEach(discovered) { service in
                        deviceRow(name: service.name, detail: "Wi‑Fi · " + service.endpoint.description, wireless: true) {
                            Button(l10n.text("连接")) { connect(service.endpoint, service: service) }.disabled(!readyForAction)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if entry != .usb {
                if nearby.isEmpty && !devices.contains(where: { $0.isWireless && $0.isOnline }) {
                    if discoveryError {
                    WorkspaceNotice(message: l10n.text("自动发现暂不可用。已配对的设备可通过当前连接地址接入。"))
                    } else if discoveryStarted {
                        WorkspaceNotice(message: l10n.text("手机和 Mac 请连接同一 Wi‑Fi。在手机的「开发者选项 → 无线调试」打开开关，首次使用请点下方的「配对新设备」。"))
                    } else {
                        WorkspaceNotice(message: l10n.text("正在查找无线设备…"), loading: true)
                    }
                }
                HStack {
                    Button(l10n.text("输入连接地址"), action: openManualAddress).disabled(!readyForAction)
                    if #available(macOS 15, *), discoveryStarted, nearby.isEmpty,
                       !devices.contains(where: { $0.isWireless && $0.isOnline }) {
                        localNetworkSettings
                    }
                }
            }
            if devices.contains(where: { !$0.isWireless && $0.state == "unauthorized" }) {
                WorkspaceNotice(message: l10n.text("手机已接入。请解锁手机，在「允许 USB 调试」弹窗点「允许」。如果没看到弹窗，请拔插数据线后再看手机屏幕。"))
            } else if entry == .usb && devices.isEmpty {
                WorkspaceNotice(message: l10n.text("未检测到 USB 手机。请用支持数据传输的线缆连接 Mac，解锁手机，并在「开发者选项」开启 USB 调试。"))
            } else if entry != .wireless && devices.contains(where: { !$0.isWireless && $0.state == "offline" }) {
                WorkspaceNotice(message: l10n.text("USB 设备已离线。请重新插拔数据线，解锁手机并确认 USB 调试已开启。"))
            } else if entry == .all && devices.isEmpty && !offersReconnect && discovered.isEmpty {
                Text(l10n.text("也可插入数据线，在手机上开启并允许 USB 调试。")).font(.caption).foregroundStyle(HubStyle.muted)
            }
        }
    }

    private var localNetworkSettings: some View {
        Link(l10n.text("打开 Mac 局域网设置"),
             destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
            .help(l10n.text("若曾拒绝局域网访问，请在系统设置中允许 DroidHub，再返回刷新。"))
    }

    private func detail(for device: AndroidDevice) -> String {
        let transport = device.isWireless ? "Wi‑Fi" : "USB"
        if device.state == "unauthorized" { return l10n.text("{1} · 请解锁手机并允许 USB 调试", transport) }
        return "\(transport) · \(device.statusLabel)"
    }

    private func deviceRow<Actions: View>(name: String, detail: String, wireless: Bool,
                                          @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 10) {
            Image(systemName: wireless ? "wifi" : "cable.connector")
                .foregroundStyle(HubStyle.accent).frame(width: 23).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).fontWeight(.medium).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(HubStyle.muted).lineLimit(1)
            }
            Spacer()
            actions().font(.caption)
        }.padding(.horizontal, 12).frame(height: 46)
            .background(HubStyle.well)
    }

    private var addDeviceForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(l10n.text("无线方式"), selection: Binding(get: { method }, set: { selected in
                guard selected != method else { return }
                expectedManualFingerprint = nil
                changeMode()
                method = selected
            })) {
                ForEach(Method.allCases) { Text(l10n.text($0.rawValue)).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            switch method {
            case .qr:
                HStack(spacing: 18) {
                    if let qrImage {
                        Image(nsImage: qrImage).interpolation(.none).resizable()
                            .frame(width: 146, height: 146).padding(12).background(Color.white)
                            .accessibilityLabel(l10n.text("无线调试配对二维码"))
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(l10n.text("在手机的「无线调试」中选择「使用二维码配对」。"))
                            .font(.callout).foregroundStyle(HubStyle.muted)
                        if qrImage == nil, operation == nil {
                            ToolbarAction(title: l10n.text("生成二维码"), symbol: "qrcode", prominent: true, action: start)
                                .disabled(!canStart)
                        }
                    }
                    Spacer(minLength: 0)
                }
            case .code:
                Text(l10n.text("在手机上选择「使用配对码配对」，保持弹窗打开，再填写弹窗显示的地址和配对码。"))
                    .font(.caption).foregroundStyle(HubStyle.muted)
                field(l10n.text("配对弹窗的 IP 地址和端口"), $pairingAddress, prompt: "192.168.1.23:37123")
                field(l10n.text("手机系统的 6 位配对码"), $code, secure: true)
                let pairing = services.filter { $0.kind == .pairing }
                if !pairing.isEmpty {
                    Menu(l10n.text("使用发现的配对地址")) {
                        ForEach(pairing) { service in
                            Button(service.endpoint.description) { pairingAddress = service.endpoint.description }
                        }
                    }.disabled(operation != nil)
                }
                DisclosureGroup(l10n.text("手动指定连接地址（可选）"), isExpanded: $showsConnectionAddress) {
                    field(l10n.text("无线调试主页的 IP 地址和端口"), $connectionAddress, prompt: "192.168.1.23:35299")
                        .padding(.top, 5)
                }
            case .address:
                field(l10n.text("无线调试主页的 IP 地址和端口"), $connectionAddress, prompt: "192.168.1.23:35299")
                Text(l10n.text("此方式用于已配对的 Mac。请填写无线调试主页的当前地址，配对弹窗里的端口只用于配对。"))
                    .font(.caption).foregroundStyle(HubStyle.muted)
            }
        }
    }

    private func field(_ label: String, _ value: Binding<String>, prompt: String? = nil, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(HubStyle.muted)
            if secure { SecureField(label, text: value) }
            else { TextField(label, text: value, prompt: prompt.map { Text($0) }) }
            if !value.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if secure && !validPairingCode {
                    Text(l10n.text("请输入手机显示的 6 位数字。")).font(.caption).foregroundStyle(HubStyle.error)
                } else if !secure && ADBEndpoint(value.wrappedValue) == nil {
                    Text(l10n.text("请输入完整的 IP 地址和端口。")).font(.caption).foregroundStyle(HubStyle.error)
                }
            }
        }.textFieldStyle(.roundedBorder).disabled(operation != nil)
    }

    private var validPairingCode: Bool {
        code.utf8.count == 6 && code.utf8.allSatisfy { (48...57).contains($0) }
    }

    private var canStart: Bool {
        guard readyForAction else { return false }
        switch method {
        case .qr: return true
        case .address: return ADBEndpoint(connectionAddress) != nil
        case .code:
            return ADBEndpoint(pairingAddress) != nil && validPairingCode &&
                (!showsConnectionAddress || connectionAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ADBEndpoint(connectionAddress) != nil)
        }
    }

    private func changeMode() {
        cancel()
        failed = false
        failure = nil
        code = ""
    }

    private func returnToDevices() {
        changeMode()
        expectedManualFingerprint = nil
        addingDevice = false
    }

    private func cancel() {
        attempt = UUID()
        operation?.cancel()
        operation = nil
        qrImage = nil
        status = nil
    }

    private func start() {
        guard canStart else { return }
        let adb = model.adb, selectedMethod = method
        let pairEndpoint = ADBEndpoint(pairingAddress)
        let target = selectedMethod == .code && !showsConnectionAddress ? nil : ADBEndpoint(connectionAddress)
        let secret = code
        let knownService = nearby.first { $0.endpoint == target }
        code = ""
        runConnection(expectedFingerprint: selectedMethod == .address ? expectedManualFingerprint : nil) {
            switch selectedMethod {
            case .qr:
                let name = "studio-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
                let password = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                qrImage = try makeQRCode("WIFI:T:ADB;S:\(name);P:\(password);;")
                phase = .pairing
                status = .message("等待手机扫码，二维码 60 秒后失效。")
                let service = try await waitForQRCode(adb, name: name)
                try Task.checkCancellation()
                qrImage = nil
                status = .message("正在配对…")
                let guid = try await adb.pairWireless(service.endpoint, secret: password)
                return try await connectPaired(adb, guid: guid, host: service.endpoint.host)
            case .code:
                guard let pairEndpoint else { throw CancellationError() }
                phase = .pairing
                status = .message("正在配对…")
                let guid = try await adb.pairWireless(pairEndpoint, secret: secret)
                try Task.checkCancellation()
                if let target {
                    phase = .connecting
                    addressSource = .manual
                    status = .message("配对完成，正在连接…")
                    return WirelessConnection(device: try await adb.connectWireless(target, service: knownService),
                                              endpoint: target, service: knownService)
                }
                return try await connectPaired(adb, guid: guid, host: pairEndpoint.host)
            case .address:
                guard let target else { throw CancellationError() }
                phase = .connecting
                addressSource = .manual
                status = .message("正在连接设备…")
                return WirelessConnection(device: try await adb.connectWireless(target, service: knownService),
                                          endpoint: target, service: knownService)
            }
        }
    }

    private struct WirelessConnection {
        let device: AndroidDevice
        let endpoint: ADBEndpoint?
        let service: ADBWirelessService?
        var verifiedFingerprint: String? = nil
    }

    private func connect(_ endpoint: ADBEndpoint, service: ADBWirelessService?) {
        guard readyForAction else { return }
        let adb = model.adb
        runConnection {
            phase = .connecting
            addressSource = .discovered
            status = .message("正在连接设备…")
            return WirelessConnection(device: try await adb.connectWireless(endpoint, service: service),
                                      endpoint: endpoint, service: service)
        }
    }

    private func reconnect(_ saved: RecentDevice) {
        guard readyForAction else { return }
        let adb = model.adb
        let previous = saved.address.flatMap(ADBEndpoint.init)
        let usb = model.devices.filter { $0.isOnline && !$0.isWireless }
        let nearbyMatch = ADBWirelessService.reconnectionService(in: nearby, serial: saved.serviceSerial,
                                                                 previous: previous, canVerifyIdentity: saved.fingerprint != nil)
        runConnection(expectedFingerprint: saved.fingerprint) {
            async let discovery = try? adb.wirelessServices()
            var rejectedSavedAddress = false
            if let previous, let fingerprint = saved.fingerprint,
               nearbyMatch == nil || nearbyMatch?.endpoint == previous {
                do {
                    var connection = try await connectResolved(previous, service: nearbyMatch, source: .previous,
                                                               adb: adb, quickAttempt: true)
                    try Task.checkCancellation()
                    phase = .identity
                    status = .message("正在核对设备身份…")
                    let serial = try? await adb.hardwareSerial(for: connection.device)
                    try Task.checkCancellation()
                    if serial.map(TransferDeviceID.hardwareFingerprint) == fingerprint {
                        connection.verifiedFingerprint = fingerprint
                        return connection
                    }
                    rejectedSavedAddress = serial != nil
                } catch {
                    try Task.checkCancellation()
                }
            }
            phase = .discovery
            status = .message("正在查找这台手机的当前连接地址…")
            let fresh = await discovery ?? []
            try Task.checkCancellation()
            let found = ADBWirelessService.reconnectionService(in: fresh, serial: saved.serviceSerial,
                                                                 previous: previous,
                                                                 canVerifyIdentity: saved.fingerprint != nil)
            // The open list may already have the new port if this discovery round missed it.
            let current = found ?? nearbyMatch
            if let found = current, found.endpoint != previous {
                do { return try await connectResolved(found.endpoint, service: found, source: .discovered, adb: adb) }
                catch let error as ADBWirelessFailure where error.needsConnectionAddress {
                    if let alternate = try await matchingUSBEndpoint(usb, fingerprint: saved.fingerprint, adb: adb),
                       alternate != found.endpoint {
                        return try await connectResolved(alternate, service: nil, source: .usb, adb: adb)
                    }
                    phase = .connecting
                    throw error
                }
            }
            if let alternate = try await matchingUSBEndpoint(usb, fingerprint: saved.fingerprint, adb: adb),
               alternate != previous {
                return try await connectResolved(alternate, service: nil, source: .usb, adb: adb)
            }
            if let found = current, !rejectedSavedAddress {
                return try await connectResolved(found.endpoint, service: found, source: .discovered, adb: adb)
            }
            guard let previous else { throw ADBWirelessFailure.addressUnavailable }
            guard saved.fingerprint != nil, !rejectedSavedAddress else { throw ADBWirelessFailure.identityMismatch }
            do { return try await connectResolved(previous, service: nil, source: .previous, adb: adb) }
            catch let error as ADBWirelessFailure where error.needsConnectionAddress {
                let refreshed = (try? await adb.wirelessServices()) ?? []
                try Task.checkCancellation()
                if let discovered = ADBWirelessService.reconnectionService(in: refreshed, serial: saved.serviceSerial,
                                                                           previous: previous, canVerifyIdentity: true),
                   discovered.endpoint != previous {
                    return try await connectResolved(discovered.endpoint, service: discovered, source: .discovered, adb: adb)
                }
                throw error
            }
        }
    }

    private func matchingUSBEndpoint(_ devices: [AndroidDevice], fingerprint: String?, adb: ADBClient) async throws -> ADBEndpoint? {
        guard let fingerprint else { return nil }
        phase = .discovery
        for device in devices {
            try Task.checkCancellation()
            guard let serial = try? await adb.hardwareSerial(for: device),
                  TransferDeviceID.hardwareFingerprint(serial) == fingerprint else { continue }
            let endpoint = try? await adb.wirelessEndpoint(overUSB: device)
            try Task.checkCancellation()
            return endpoint
        }
        return nil
    }

    private func connectResolved(_ endpoint: ADBEndpoint, service: ADBWirelessService?, source: AddressSource,
                                 adb: ADBClient, quickAttempt: Bool = false) async throws -> WirelessConnection {
        phase = .connecting
        addressSource = source
        status = source == .previous ? .message("正在尝试上次的连接地址…") : .message("已找到当前地址，正在连接…")
        let device = try await adb.connectWireless(endpoint, service: service, quickAttempt: quickAttempt)
        return WirelessConnection(device: device, endpoint: endpoint, service: service)
    }

    private func showAddressRecovery() {
        let fingerprint = activeFingerprint
        openManualAddress()
        expectedManualFingerprint = fingerprint
    }

    private func openManualAddress() {
        changeMode()
        expectedManualFingerprint = nil
        addingDevice = true
        method = .address
        connectionAddress = ""
        status = .message("请填写手机「无线调试」主页当前显示的 IP 地址和端口。")
    }

    private func copyDiagnostic() {
        let adb = model.adb
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? l10n.text("未知")
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let usb = model.devices.filter { !$0.isWireless }
        let waiting = usb.filter { $0.state == "unauthorized" }.count
        let wirelessOnline = model.devices.filter { $0.isWireless && $0.isOnline }.count
        let available = nearby.count
        let discovery = discoveryError ? l10n.text("不可用") : (discoveryStarted ? l10n.text("已检查") : l10n.text("等待检查"))
        let diagnostic = lastDiagnostic
        copyingDiagnostic = true
        Task {
            let adbVersion = await adb.diagnosticVersion() ?? l10n.text("未读取")
            let text = [
                "DroidHub \(version)",
                "macOS \(system.majorVersion).\(system.minorVersion).\(system.patchVersion)",
                "ADB \(adbVersion)",
                l10n.text("USB 在线 {1}，等待授权 {2}", usb.filter(\.isOnline).count, waiting),
                l10n.text("Wi-Fi 在线 {1}，发现连接服务 {2}", wirelessOnline, available),
                l10n.text("无线发现 {1}", discovery),
                l10n.text("最近阶段 {1}", l10n.text(diagnostic?.phase.rawValue ?? (waiting > 0 ? "等待 USB 授权" : "未进行连接"))),
                l10n.text("地址来源 {1}", l10n.text(diagnostic?.source?.rawValue ?? "—")),
                l10n.text("结果 {1}", diagnostic?.result ?? "—")
            ].joined(separator: "\n")
            NSPasteboard.general.clearContents()
            copiedDiagnostic = NSPasteboard.general.setString(text, forType: .string)
            copyingDiagnostic = false
        }
    }

    private func runConnection(expectedFingerprint: String? = nil, _ action: @escaping @MainActor () async throws -> WirelessConnection) {
        let id = UUID(), adb = model.adb
        attempt = id
        failed = false
        failure = nil
        phase = .discovery
        addressSource = nil
        activeFingerprint = expectedFingerprint
        copiedDiagnostic = false
        operation = Task { @MainActor in
            defer {
                if attempt == id { operation = nil; qrImage = nil }
            }
            do {
                let connection = try await action()
                let device = connection.device
                let fingerprint: String?
                if let verified = connection.verifiedFingerprint {
                    fingerprint = verified
                } else {
                    phase = .identity
                    status = .message("正在核对设备身份…")
                    let serial = try? await adb.hardwareSerial(for: device)
                    fingerprint = serial.map(TransferDeviceID.hardwareFingerprint)
                }
                try Task.checkCancellation()
                guard attempt == id, adb.executable == model.adbPath else { return }
                if let expectedFingerprint, expectedFingerprint != fingerprint {
                    throw ADBWirelessFailure.identityMismatch
                }
                remember(device, endpoint: connection.endpoint, service: connection.service, fingerprint: fingerprint)
                guard !model.busy else { throw HubError.message(l10n.text("设备已上线。请在当前任务完成后从设备列表选择它。")) }
                model.selectWirelessDevice(device)
                status = .connected(device.model)
                lastDiagnostic = ConnectionDiagnostic(phase: .connected, source: addressSource, result: l10n.text("成功"))
            } catch {
                guard attempt == id, !Task.isCancelled else { return }
                failed = true
                failure = error as? ADBWirelessFailure
                lastDiagnostic = ConnectionDiagnostic(phase: phase, source: addressSource,
                                                      result: failure?.rawValue ?? l10n.text("连接操作未完成"))
                status = .failure(error.localizedDescription)
            }
        }
    }

    private func currentFingerprint(for device: AndroidDevice) -> String? {
        guard let connection = model.transfers.connection, connection.serial == device.serial,
              case .hardware(let fingerprint) = connection.deviceID else { return nil }
        return fingerprint
    }

    private func remember(_ device: AndroidDevice, endpoint: ADBEndpoint?, service: ADBWirelessService?, fingerprint: String? = nil) {
        let saved = recent
        let sameDevice = saved?.matches(device) == true || (service != nil && saved?.serviceSerial == service?.serial)
        let serviceSerial = service?.serial ?? (ADBEndpoint(device.serial) == nil ? RecentDevice.normalize(device.serial) : nil)
        let record = RecentDevice(model: device.model,
                                  address: (service?.endpoint ?? endpoint ?? ADBEndpoint(device.serial))?.description ?? (sameDevice ? saved?.address : nil),
                                  serviceSerial: serviceSerial ?? (sameDevice ? saved?.serviceSerial : nil),
                                  fingerprint: fingerprint ?? (sameDevice ? saved?.fingerprint : nil))
        if let encoded = try? JSONEncoder().encode(record) { recentData = encoded }
    }

    private func waitForQRCode(_ adb: ADBClient, name: String) async throws -> ADBWirelessService {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(60))
        while clock.now < deadline {
            try Task.checkCancellation()
            let matches = try await adb.wirelessServices().filter { $0.kind == .pairing && $0.name == name }
            if matches.count == 1, let match = matches.first { return match }
            try await Task.sleep(nanoseconds: 850_000_000)
        }
        throw ADBWirelessFailure.scanExpired
    }

    private func connectPaired(_ adb: ADBClient, guid: String?, host: String) async throws -> WirelessConnection {
        try Task.checkCancellation()
        phase = .discovery
        status = .message("配对完成，正在查找连接地址…")
        for _ in 0..<8 {
            try Task.checkCancellation()
            if let guid, let device = try await adb.devices().first(where: {
                $0.isOnline && $0.isWireless && ($0.serial.hasPrefix(guid + "-") || $0.serial.hasPrefix(guid + "."))
            }) {
                addressSource = .discovered
                return WirelessConnection(device: device, endpoint: nil, service: service(for: device))
            }
            if let found = try? await adb.wirelessServices(),
               let service = ADBWirelessService.connection(in: found, guid: guid, host: host) {
                return try await connectResolved(service.endpoint, service: service, source: .discovered, adb: adb)
            }
            try await Task.sleep(nanoseconds: 650_000_000)
        }
        throw ADBWirelessFailure.pairedNeedsAddress
    }

    private func makeQRCode(_ value: String) throws -> NSImage {
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(value.utf8)
        generator.correctionLevel = "M"
        guard let image = generator.outputImage,
              let pixels = CIContext().createCGImage(image, from: image.extent) else {
            throw HubError.message(l10n.text("二维码生成失败，可以使用配对码连接。"))
        }
        return NSImage(cgImage: pixels, size: NSSize(width: pixels.width, height: pixels.height))
    }
}
