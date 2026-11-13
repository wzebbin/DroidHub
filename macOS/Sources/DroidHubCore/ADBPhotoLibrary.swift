import Foundation

public struct ADBPhotoLibrary: Sendable {
    public let cacheID = UUID().uuidString
    let thumbnailCacheDevice: String?
    private let adb: ADBClient
    private let serial: String

    public init(adb: ADBClient, serial: String, thumbnailCacheDevice: String? = nil) {
        self.adb = adb
        self.serial = serial
        self.thumbnailCacheDevice = thumbnailCacheDevice
    }

    public func photos(expectedUser: Int? = nil) async throws -> [MediaItem] {
        try await scan(roots: ["/sdcard/DCIM", "/sdcard/Pictures"], expectedUser: expectedUser)
    }

    public func videos(expectedUser: Int? = nil) async throws -> [MediaItem] {
        try await scan(roots: ["/sdcard/DCIM", "/sdcard/Pictures", "/sdcard/Movies"],
                       extensions: MediaItem.videoExtensions, expectedUser: expectedUser)
    }

    func scan(roots: [String], extensions: [String] = ["jpg", "jpeg", "png", "webp", "gif", "heic",
                                                      "heif", "avif", "bmp", "tif", "tiff", "dng"],
              expectedUser: Int? = nil) async throws -> [MediaItem] {
        let patterns = extensions.map { "-iname '*." + $0 + "'" }.joined(separator: " -o ")
        let verifyUser = expectedUser.map {
            #"[ "$(am get-current-user)" = "\#($0)" ] || { echo '手机用户已切换，请刷新图库。' >&2; exit 1; }"#
        } ?? ""
        let script = #"""
        set -e
        \#(verifyUser)
        set --
        for folder in \#(roots.map(Shell.quote).joined(separator: " ")); do
            if [ -d "$folder" ]; then set -- "$@" "$folder"; fi
        done
        [ "$#" -gt 0 ] || exit 0
        if find / -maxdepth 0 -printf '' >/dev/null 2>&1; then
            find "$@" -name '.*' -prune -o -type f \( \#(patterns) \) -printf '%T@\0%s\0%p\0'
        else
            find "$@" -name '.*' -prune -o -type f \( \#(patterns) \) -exec sh -c '
                for file do
                    metadata=$(stat -c "%Y %s" -- "$file" 2>/dev/null) || continue
                    printf "%s\0%s\0%s\0" "${metadata%% *}" "${metadata#* }" "$file"
                done
            ' sh {} +
        fi
        \#(verifyUser)
        """#
        let data = try await adb.shell(serial: serial, script: script, timeout: 90)
        try Task.checkCancellation()
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> [MediaItem] {
        guard !data.isEmpty else { return [] }
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.count % 3 == 1, fields.last?.isEmpty == true else {
            throw HubError.message("手机返回的媒体列表不完整，请刷新图库。")
        }
        var photos: [MediaItem] = []
        var seen = Set<String>()
        for index in stride(from: 0, to: fields.count - 1, by: 3) {
            guard let modifiedAt = Double(String(decoding: fields[index], as: UTF8.self)), modifiedAt.isFinite,
                  let bytes = Int64(String(decoding: fields[index + 1], as: UTF8.self)), bytes >= 0,
                  let path = String(bytes: fields[index + 2], encoding: .utf8), path.hasPrefix("/"),
                  seen.insert(path).inserted else { continue }
            photos.append(MediaItem(path: path, bytes: bytes, modifiedAt: modifiedAt))
        }
        return photos.sorted {
            $0.modifiedAt == $1.modifiedAt ? $0.path < $1.path : $0.modifiedAt > $1.modifiedAt
        }
    }

    public func export(_ item: MediaItem, destination: URL, replaceExisting: Bool) async throws {
        try await downloadMedia(item, to: destination, replaceExisting: replaceExisting)
    }

    func download(_ item: MediaItem, to destination: URL) async throws {
        try await adb.download(serial: serial, remote: item.path, local: destination)
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == item.bytes else {
            throw HubError.message("文件已变更或下载不完整，请刷新图库后重试。")
        }
    }

    public func downloadVideo(_ item: MediaItem, to destination: URL,
                              progress: @escaping @Sendable (TransferProgress) async -> Void) async throws {
        try await downloadMedia(item, to: destination, replaceExisting: false, progress: progress)
    }

    private func downloadMedia(_ item: MediaItem, to destination: URL, replaceExisting: Bool,
                               progress: (@Sendable (TransferProgress) async -> Void)? = nil) async throws {
        let file = DeviceFile(name: item.name, path: item.path, isDirectory: false, size: item.bytes)
        try await adb.downloadFile(serial: serial, file: file, destination: destination,
                                   replaceExisting: replaceExisting, progress: progress)
    }

    func photoPrefix(_ item: MediaItem, count: Int) async throws -> Data {
        let data = try await adb.shell(serial: serial, script: "head -c \(count) -- \(Shell.quote(item.path))", timeout: 8)
        guard data.count == count else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }

    func readVideo(_ item: MediaItem, offset: Int64, count: Int) async throws -> Data {
        let block: Int64 = 65_536
        let start = Int(offset % block)
        let blocks = (Int64(start + count) + block - 1) / block
        let script = "dd if=\(Shell.quote(item.path)) bs=\(block) skip=\(offset / block) count=\(blocks) 2>/dev/null"
        let data = try await adb.shell(serial: serial, script: script, timeout: 8)
        guard data.count >= start + count else { throw CocoaError(.fileReadCorruptFile) }
        return data.subdata(in: start..<(start + count))
    }
}
