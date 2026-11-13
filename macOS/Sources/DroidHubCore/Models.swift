import Foundation

public struct AndroidDevice: Identifiable, Hashable, Sendable {
    public var id: String { serial }
    public let serial: String
    public let state: String
    public let model: String
    public let transportID: String?
    public var isOnline: Bool { state == "device" }
    public var isWireless: Bool { ADBEndpoint(serial) != nil || serial.hasSuffix("._adb-tls-connect._tcp") || serial.hasSuffix("._adb-tls-connect._tcp.local") }
    public var statusLabel: String {
        switch state {
        case "device": return L10n.text("已连接")
        case "unauthorized": return L10n.text("请在手机上允许 USB 调试")
        case "offline": return L10n.text("设备离线")
        default: return state
        }
    }

    public static func parse(_ output: String) -> [Self] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, !line.hasPrefix("List of"), !line.hasPrefix("*") else { return nil }
            let model = fields.first(where: { $0.hasPrefix("model:") })
                .map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") } ?? fields[0]
            let transportID = fields.first { $0.hasPrefix("transport_id:") }.map { String($0.dropFirst(13)) }
            return Self(serial: fields[0], state: fields[1], model: model, transportID: transportID)
        }
    }
}

public struct DeviceFile: Identifiable, Hashable, Codable, Sendable {
    private static let folderPriority = ["DCIM", "Pictures", "Movies", "Music", "Download", "Documents"]
    public var id: String { path }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: Int64

    public static func parse(_ data: Data, directory: String) throws -> [Self] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.count % 3 == 1, fields.last?.isEmpty == true else {
            throw HubError.message(L10n.text("设备返回了不完整的目录数据。"))
        }
        return stride(from: 0, to: fields.count - 1, by: 3).map { i in
            let name = String(decoding: fields[i], as: UTF8.self)
            return Self(name: name, path: directory == "/" ? "/" + name : directory + "/" + name,
                        isDirectory: fields[i + 1] == Data("d".utf8),
                        size: Int64(String(decoding: fields[i + 2], as: UTF8.self)) ?? 0)
        }.sorted {
            let left = $0.isDirectory ? (folderPriority.firstIndex(of: $0.name) ?? folderPriority.count) : folderPriority.count + 1
            let right = $1.isDirectory ? (folderPriority.firstIndex(of: $1.name) ?? folderPriority.count) : folderPriority.count + 1
            return left == right ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : left < right
        }
    }
}

public struct MediaItem: Identifiable, Hashable, Codable, Sendable {
    static let videoExtensions = ["mp4", "m4v", "mov", "3gp", "3g2", "mkv", "webm", "avi"]
    public let path: String
    public let bytes: Int64
    public let modifiedAt: Double
    public var id: String { path }
    public let name: String
    public var isVideo: Bool { Self.videoExtensions.contains((path as NSString).pathExtension.lowercased()) }

    public init(path: String, bytes: Int64, modifiedAt: Double) {
        self.path = path
        self.bytes = bytes
        self.modifiedAt = modifiedAt
        self.name = (path as NSString).lastPathComponent
    }

    private enum CodingKeys: String, CodingKey { case path, bytes, modifiedAt }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(path: try values.decode(String.self, forKey: .path),
                  bytes: try values.decode(Int64.self, forKey: .bytes),
                  modifiedAt: try values.decode(Double.self, forKey: .modifiedAt))
    }
}

public enum HubError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        if case .message(let value) = self { return value }
        return nil
    }
}

public enum Shell {
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func directoryScript(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw HubError.message(L10n.text("请输入绝对路径。"))
        }
        return """
        dir=\(quote(path))
        [ -d "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] || { echo '目录不存在或无访问权限' >&2; exit 1; }
        if find / -maxdepth 0 -printf '%f\\0%s\\0' >/dev/null 2>&1; then
          find -H "$dir" -mindepth 1 -maxdepth 1 \\( \\( -type l -exec sh -c '
              for f do
                kind=f; [ ! -d "$f" ] || kind=d
                size=$(stat -c %s "$f" 2>/dev/null) || size=0
                printf "%s\\000%s\\000%s\\000" "${f##*/}" "$kind" "$size"
              done
            ' sh {} + \\) -o \\( -type d -printf '%f\\0d\\0%s\\0' \\) -o -printf '%f\\0f\\0%s\\0' \\)
          exit $?
        fi
        for f in "$dir"/.[!.]* "$dir"/..?* "$dir"/*; do
          [ -e "$f" ] || [ -L "$f" ] || continue
          name=${f##*/}
          kind=f; [ ! -d "$f" ] || kind=d
          size=$(stat -c %s "$f" 2>/dev/null) || size=0
          printf '%s\\000%s\\000%s\\000' "$name" "$kind" "$size"
        done
        """
    }
}
