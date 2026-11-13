import Foundation
import Darwin

public struct ADBEndpoint: Hashable, Sendable, CustomStringConvertible {
    public let host: String
    public let port: Int
    public var description: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }

    public init?(host: String, port: String) {
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let unbracketed = address.hasPrefix("[") && address.hasSuffix("]") ? String(address.dropFirst().dropLast()) : address
        let portText = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !portText.isEmpty, portText.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(portText), (1...65535).contains(number) else { return nil }
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        if inet_pton(AF_INET, unbracketed, &ipv4) == 1 {
            self.host = unbracketed
        } else if inet_pton(AF_INET6, unbracketed, &ipv6) == 1 {
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &ipv6, &text, socklen_t(text.count)) != nil else { return nil }
            self.host = String(cString: text)
        } else {
            return nil
        }
        self.port = number
    }

    public init?(_ address: String) {
        guard let separator = address.lastIndex(of: ":") else { return nil }
        self.init(host: String(address[..<separator]), port: String(address[address.index(after: separator)...]))
    }
}

public struct ADBWirelessService: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case pairing = "_adb-tls-pairing._tcp"
        case connection = "_adb-tls-connect._tcp"
    }
    public let name: String
    public let kind: Kind
    public let endpoint: ADBEndpoint
    public var id: String { "\(name).\(kind.rawValue)@\(endpoint)" }
    public var serial: String { "\(name).\(kind.rawValue)" }

    public static func parse(_ output: String) -> [Self] {
        var seen = Set<Self>()
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3,
                  let kind = Kind(rawValue: String(fields[1]).trimmingCharacters(in: CharacterSet(charactersIn: "."))),
                  let endpoint = ADBEndpoint(String(fields[2])) else { return nil }
            let service = Self(name: String(fields[0]), kind: kind, endpoint: endpoint)
            return seen.insert(service).inserted ? service : nil
        }
    }

    public static func connection(in services: [Self], guid: String?, host: String) -> Self? {
        let matches = services.filter { service in
            guard service.kind == .connection else { return false }
            if let guid { return service.name == guid || service.name.hasPrefix(guid + "-") }
            return service.endpoint.host == host
        }
        return matches.count == 1 ? matches.first : nil
    }

    static func merging(adb: [Self], bonjour: [Self]) -> [Self] {
        let resolvedSerials = Set(bonjour.map(\.serial))
        return bonjour + adb.filter { !resolvedSerials.contains($0.serial) }
    }

    public static func reconnectionService(in services: [Self], serial: String?, previous: ADBEndpoint?,
                                           canVerifyIdentity: Bool) -> Self? {
        let connections = services.filter { $0.kind == .connection }
        if let serial {
            let exact = connections.filter { $0.serial == serial }
            if exact.count == 1 { return exact.first }
            if !exact.isEmpty {
                let onPreviousHost = exact.filter { $0.endpoint.host == previous?.host }
                return onPreviousHost.count == 1 ? onPreviousHost.first : nil
            }
        }
        guard canVerifyIdentity, let previous else { return nil }
        let onPreviousHost = connections.filter { $0.endpoint.host == previous.host }
        return onPreviousHost.count == 1 ? onPreviousHost.first : nil
    }
}

public enum ADBWirelessFailure: String, LocalizedError, Sendable {
    case pairingFailed, scanExpired, addressUnavailable, networkUnavailable, unauthorized, timedOut, notOnline
    case identityMismatch, pairedNeedsAddress

    public var needsConnectionAddress: Bool {
        switch self {
        case .addressUnavailable, .timedOut, .notOnline, .identityMismatch, .pairedNeedsAddress: return true
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .pairingFailed: return L10n.text("无线配对失败。请重新打开手机上的配对窗口，确认地址和配对码后重试。")
        case .scanExpired: return L10n.text("扫码等待超时。请重新生成二维码，或使用配对码。")
        case .addressUnavailable: return L10n.text("连接地址已失效或手机未监听。请打开手机「无线调试」主页，使用当前显示的地址。")
        case .networkUnavailable: return L10n.text("Mac 无法访问手机。请确认在同一网络，并在「隐私与安全性 → 本地网络」中允许 DroidHub。")
        case .unauthorized: return L10n.text("手机未接受这台 Mac 的无线调试授权。请在手机上确认，或重新配对。")
        case .timedOut: return L10n.text("无线连接超时。请确认两台设备在同一网络，再核对手机无线调试主页的地址。")
        case .notOnline: return L10n.text("手机尚未通过 Wi‑Fi 上线。请确认这台 Mac 已配对，并检查填写的是无线调试主页的连接地址。")
        case .identityMismatch: return L10n.text("无法确认这是上次连接的手机。请核对手机无线调试主页的地址后手动连接。")
        case .pairedNeedsAddress: return L10n.text("配对已完成。请填写手机「无线调试」主页当前显示的连接地址。")
        }
    }
}

extension ADBClient {
    public func deviceEvents() -> AsyncThrowingStream<Void, Error> { ProcessRunner.deviceEvents(executable) }

    public func wirelessServices() async throws -> [ADBWirelessService] {
        async let bonjour = ADBWirelessBonjour().discover()
        do {
            let data = try await ProcessRunner.run(executable, ["mdns", "services"], timeout: 5)
            let services = await ADBWirelessService.merging(
                adb: ADBWirelessService.parse(String(decoding: data, as: UTF8.self)), bonjour: bonjour)
            try Task.checkCancellation()
            return services
        } catch {
            try Task.checkCancellation()
            let services = await bonjour
            try Task.checkCancellation()
            guard !services.isEmpty else { throw error }
            return services
        }
    }

    public func wirelessEndpoint(overUSB device: AndroidDevice) async throws -> ADBEndpoint? {
        guard device.isOnline, !device.isWireless else { return nil }
        let data = try await shell(serial: device.serial, script: """
            port=$(getprop service.adb.tls.port)
            if [ -z "$port" ] || [ "$port" = -1 ] || [ "$port" = 0 ]; then
              port=$(dumpsys -t 2 adb 2>/dev/null | awk '
                /^[[:space:]]*adb_wifi=[{]/ { wifi=1; next }
                wifi && /^[[:space:]]*}/ { exit }
                wifi && /^[[:space:]]*enabled=true/ { enabled=1 }
                wifi && enabled && /^[[:space:]]*tls_port=[0-9]+$/ {
                  sub(/.*=/, ""); print; exit
                }')
            fi
            [ -n "$port" ] || exit 0
            interface=$(getprop wifi.interface)
            [ -n "$interface" ] || interface=wlan0
            ip -o addr show dev "$interface" scope global 2>/dev/null | awk -v port="$port" '
              $3 == "inet" && !ipv4 { split($4, parts, "/"); ipv4=parts[1] }
              $3 == "inet6" && !ipv6 { split($4, parts, "/"); ipv6=parts[1] }
              END {
                if (ipv4) print ipv4 ":" port
                else if (ipv6) print "[" ipv6 "]:" port
              }'
            """, timeout: 5)
        try Task.checkCancellation()
        return ADBEndpoint(String(decoding: data, as: UTF8.self))
    }

    public func diagnosticVersion() async -> String? {
        guard !executable.isEmpty,
              let output = try? await ProcessRunner.run(executable, ["version"], timeout: 3) else { return nil }
        let text = String(decoding: output, as: UTF8.self)
        for prefix in ["Version ", "Android Debug Bridge version "] {
            guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(prefix) }) else { continue }
            let version = line.dropFirst(prefix.count)
            if (1...32).contains(version.utf8.count),
               version.utf8.allSatisfy({ (48...57).contains($0) || $0 == 45 || $0 == 46 }) {
                return String(version)
            }
        }
        return nil
    }

    public func pairWireless(_ endpoint: ADBEndpoint, secret: String) async throws -> String? {
        guard !secret.isEmpty, secret.utf8.count <= 64,
              secret.utf8.allSatisfy({ (33...126).contains($0) }) else { throw HubError.message(L10n.text("配对码无效。")) }
        let data: Data
        do {
            data = try await ProcessRunner.run(executable, ["pair", endpoint.description], timeout: 18, input: Data((secret + "\n").utf8))
        } catch {
            try Task.checkCancellation()
            throw ADBWirelessFailure.pairingFailed
        }
        try Task.checkCancellation()
        let output = String(decoding: data, as: UTF8.self)
        guard output.contains("Successfully paired") else { throw ADBWirelessFailure.pairingFailed }
        guard let begin = output.range(of: "[guid="), let end = output[begin.upperBound...].firstIndex(of: "]") else { return nil }
        let guid = String(output[begin.upperBound..<end])
        return guid.isEmpty ? nil : guid
    }

    public func connectWireless(_ endpoint: ADBEndpoint, service: ADBWirelessService? = nil,
                                quickAttempt: Bool = false) async throws -> AndroidDevice {
        var serials = Set([service?.serial].compactMap { $0 })
        func onlineDevice() async throws -> AndroidDevice? {
            try await devices(timeout: quickAttempt ? 1 : 30).first {
                $0.isOnline && (serials.contains($0.serial) ||
                    ($0.serial.hasSuffix(".local") && serials.contains(String($0.serial.dropLast(6)))) ||
                    ADBEndpoint($0.serial) == endpoint)
            }
        }
        try Task.checkCancellation()
        if let existing = try await onlineDevice() { return existing }
        let connectOutput: String
        do {
            let data = try await ProcessRunner.run(executable, ["connect", endpoint.description], timeout: quickAttempt ? 0.75 : 12)
            connectOutput = String(decoding: data, as: UTF8.self)
        } catch {
            try Task.checkCancellation()
            if let detail = wirelessConnectionError(error.localizedDescription) { throw detail }
            throw ADBWirelessFailure.notOnline
        }
        try Task.checkCancellation()
        if let online = try await onlineDevice() { return online }
        if let detail = wirelessConnectionError(connectOutput) { throw detail }
        // A saved-address probe leaves discovery and further retries to its caller.
        if quickAttempt { throw ADBWirelessFailure.notOnline }
        if service == nil, let found = try? await wirelessServices() {
            let matches = found.filter { $0.kind == .connection && $0.endpoint == endpoint }
            if matches.count == 1, let match = matches.first { serials.insert(match.serial) }
        }
        for _ in 0..<5 {
            try Task.checkCancellation()
            if let online = try await onlineDevice() { return online }
            try await Task.sleep(nanoseconds: 350_000_000)
        }
        throw ADBWirelessFailure.notOnline
    }

    private func wirelessConnectionError(_ output: String) -> ADBWirelessFailure? {
        let message = output.lowercased()
        if message.contains("no route to host") || message.contains("network is unreachable") ||
            message.contains("operation not permitted") {
            return .networkUnavailable
        }
        if message.contains("connection refused") {
            return .addressUnavailable
        }
        if message.contains("failed to authenticate") || message.contains("unauthorized") {
            return .unauthorized
        }
        if message.contains("timed out") || message.contains("timeout") || message.contains("超时") { return .timedOut }
        return nil
    }
}
