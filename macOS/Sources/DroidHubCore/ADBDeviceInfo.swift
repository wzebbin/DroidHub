import Foundation

public struct AndroidMirrorDisplay: Sendable {
    public let name: String?
    public let size: CGSize?
}

public struct AndroidDeviceInfo: Equatable, Sendable {
    public struct Storage: Equatable, Sendable {
        public let totalBytes: Int64
        public let usedBytes: Int64
        public let availableBytes: Int64

        public var usedFraction: Double { Double(usedBytes) / Double(totalBytes) }
    }

    public struct Battery: Equatable, Sendable {
        public enum Status: Int, Equatable, Sendable {
            case charging = 2, discharging, notCharging, full
        }

        public let chargeFraction: Double?
        public let status: Status?
        public let temperatureCelsius: Double?
    }

    public let marketName: String?
    public let model: String?
    public let manufacturer: String?
    public let deviceCode: String?
    public let androidVersion: String?
    public let sdk: String?
    public let build: String?
    public let securityPatch: String?
    public let processor: String?
    public let architecture: String?
    public let screenSize: String?
    public let screenDensity: Int?
    public let storage: Storage?
    public let totalMemory: Int64?
    public let availableMemory: Int64?
    public let battery: Battery?

    fileprivate var hasReadableFields: Bool {
        [marketName, model, manufacturer, deviceCode, androidVersion, sdk, build, securityPatch, processor,
         architecture, screenSize].contains { $0 != nil }
            || screenDensity != nil || storage != nil || totalMemory != nil || battery != nil
    }

    init(output: String) {
        var sections: [String: [String]] = [:]
        var section = ""
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("@") {
                section = String(line.dropFirst())
            } else {
                sections[section, default: []].append(String(line))
            }
        }

        let properties = Self.fields(in: sections["properties"], separator: "=")
        marketName = properties["ro.product.marketname"] ?? properties["ro.product.vendor.marketname"]
        model = properties["ro.product.model"]
        manufacturer = properties["ro.product.manufacturer"]
        deviceCode = properties["ro.product.device"]
        androidVersion = properties["ro.build.version.release"]
        sdk = properties["ro.build.version.sdk"]
        build = properties["ro.build.display.id"]
        securityPatch = properties["ro.build.version.security_patch"]
        processor = [properties["ro.soc.manufacturer"], properties["ro.soc.model"]]
            .compactMap { $0 }.joined(separator: " ").nilIfEmpty
        architecture = properties["ro.product.cpu.abilist"] ?? properties["ro.product.cpu.abi"]

        let display = Self.fields(in: sections["display"], separator: ":")
        if let dimensions = display["Physical size"]?.split(separator: "x", omittingEmptySubsequences: false),
           dimensions.count == 2, let width = Int(dimensions[0]), let height = Int(dimensions[1]),
           width > 0, height > 0 {
            screenSize = "\(width) × \(height)"
        } else {
            screenSize = nil
        }
        screenDensity = display["Physical density"].flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }

        storage = sections["storage"]?.lazy.compactMap { line -> Storage? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 5, fields[4].hasSuffix("%"),
                  let total = Self.kibibytes(fields[1]), total > 0,
                  let used = Self.kibibytes(fields[2]), used <= total,
                  let available = Self.kibibytes(fields[3]), available <= total else { return nil }
            return Storage(totalBytes: total, usedBytes: used, availableBytes: available)
        }.first

        let memory = Self.fields(in: sections["memory"], separator: ":")
        let total = Self.memoryBytes(memory["MemTotal"]).flatMap { $0 > 0 ? $0 : nil }
        totalMemory = total
        availableMemory = Self.memoryBytes(memory["MemAvailable"]).flatMap { available in
            guard let total, available <= total else { return nil }
            return available
        }

        let power = Self.fields(in: sections["battery"], separator: ":")
        if power["present"] == "false" {
            battery = nil
        } else {
            let status = power["status"].flatMap { Int($0) }.flatMap(Battery.Status.init(rawValue:))
            let level = power["level"].flatMap { Int($0) }
            let scale = power["scale"].flatMap { Int($0) }
            let charge = Self.chargeFraction(level: level, scale: scale)
            let temperature = power["temperature"].flatMap { Int($0) }.map { Double($0) / 10 }
            battery = status != nil || charge != nil || temperature != nil
                ? Battery(chargeFraction: charge, status: status, temperatureCelsius: temperature) : nil
        }
    }

    private static func fields(in lines: [String]?, separator: Character) -> [String: String] {
        var fields: [String: String] = [:]
        for line in lines ?? [] {
            let parts = line.split(separator: separator, maxSplits: 1)
            guard parts.count == 2,
                  let value = parts[1].trimmingCharacters(in: .whitespaces).nilIfEmpty else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            if fields[key] == nil { fields[key] = value }
        }
        return fields
    }

    private static func kibibytes(_ value: Substring) -> Int64? {
        guard let count = Int64(value), count >= 0, count <= Int64.max / 1024 else { return nil }
        return count * 1024
    }

    private static func memoryBytes(_ value: String?) -> Int64? {
        guard let fields = value?.split(whereSeparator: \.isWhitespace),
              fields.count == 2, fields[1] == "kB" else { return nil }
        return kibibytes(fields[0])
    }

    private static func chargeFraction(level: Int?, scale: Int?) -> Double? {
        guard let level, let scale, scale > 0, (0...scale).contains(level) else { return nil }
        return Double(level) / Double(scale)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension ADBClient {
    private static let deviceNameScript = """
    name=$(getprop ro.product.marketname)
    [ -n "$name" ] || name=$(getprop ro.product.vendor.marketname)
    [ -n "$name" ] || name=$(getprop ro.product.model)
    """

    public func deviceDisplayName(for device: AndroidDevice) async throws -> String? {
        let data = try await shell(device: device, script: """
        \(Self.deviceNameScript)
        printf '%s' "$name"
        """, timeout: 3)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public func mirrorDisplay(serial: String, includeName: Bool = true) async throws -> AndroidMirrorDisplay {
        let nameScript = includeName ? """
        \(Self.deviceNameScript)
        printf 'name=%s\\n' "$name"
        """ : ""
        let data = try await shell(serial: serial, script: """
        \(nameScript)
        dumpsys -t 1 window displays 2>/dev/null | awk '
          /^[[:space:]]*Display:/ { primary = ($0 ~ /mDisplayId=0([[:space:]]|$)/) }
          primary && match($0, /[[:space:]]cur=[0-9]+x[0-9]+/) {
            print "size=" substr($0, RSTART + 5, RLENGTH - 5)
            exit
          }
        '
        """, timeout: 3)
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        let name = lines.first { $0.hasPrefix("name=") }?.dropFirst(5)
            .trimmingCharacters(in: .whitespaces).nilIfEmpty
        let dimensions = lines.first { $0.hasPrefix("size=") }?.dropFirst(5).split(separator: "x")
        let size: CGSize?
        if let dimensions, dimensions.count == 2, let width = Int(dimensions[0]), let height = Int(dimensions[1]),
           width > 0, height > 0 {
            size = CGSize(width: width, height: height)
        } else {
            size = nil
        }
        return AndroidMirrorDisplay(name: name, size: size)
    }

    public func deviceInfo(serial: String) async throws -> AndroidDeviceInfo {
        let data = try await shell(serial: serial, script: """
        printf '@properties\\n'
        for key in ro.product.marketname ro.product.vendor.marketname ro.product.model ro.product.manufacturer \\
          ro.product.device ro.build.version.release ro.build.version.sdk ro.build.display.id \\
          ro.build.version.security_patch ro.soc.manufacturer ro.soc.model ro.product.cpu.abilist ro.product.cpu.abi; do
          printf '%s=%s\\n' "$key" "$(getprop "$key")"
        done
        printf '@storage\\n'
        df -k /data 2>/dev/null
        printf '@memory\\n'
        grep -E '^(MemTotal|MemAvailable):' /proc/meminfo 2>/dev/null
        printf '@display\\n'
        wm size 2>/dev/null
        wm density 2>/dev/null
        printf '@battery\\n'
        dumpsys -t 3 battery 2>/dev/null
        :
        """, timeout: 10)
        let info = AndroidDeviceInfo(output: String(decoding: data, as: UTF8.self))
        guard info.hasReadableFields else { throw HubError.message("手机未返回可读取的设备信息，请重试。") }
        return info
    }
}
