import CryptoKit
import Darwin
import Foundation

public struct DownloadCheckpoint: Sendable {
    public static let minimumSize: Int64 = 64 * 1024 * 1024

    private let directory: URL
    fileprivate var payload: URL { directory.appendingPathComponent("payload.part") }
    fileprivate var sourceRecord: URL { directory.appendingPathComponent("source") }

    public init(destination: URL, id: UUID) {
        self.init(parent: destination.deletingLastPathComponent(), id: id)
    }

    init(parent: URL, id: UUID) {
        directory = parent.appendingPathComponent(".droidhub-resume-\(id.uuidString)", isDirectory: true)
    }

    public var savedBytes: Int64 {
        guard let values = try? payload.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize else { return 0 }
        return Int64(size)
    }

    public func discard() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let handle = try openPayload()
        defer { try? handle.close() }
        try removeDirectory()
    }

    fileprivate func openPayload() throws -> FileHandle {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch CocoaError.fileWriteFileExists {}
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink == false else {
            throw HubError.message("下载临时目录不可用。")
        }
        let fd = Darwin.open(payload.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw HubError.message("下载临时文件不可用。")
        }
        // The ADB process inherits stdout, so the lock also covers a writer left by an abrupt app exit.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw HubError.message("上次下载仍在释放临时文件，请稍后重试。")
        }
        return handle
    }

    fileprivate func removeDirectory() throws {
        try FileManager.default.removeItem(at: directory)
    }
}

extension ADBClient {
    func resumeDownload(serial: String, file: DeviceFile, destination: URL, replaceExisting: Bool,
                        checkpoint: DownloadCheckpoint, automatic: Bool,
                        beforeCommit: (@Sendable () async throws -> Void)?,
                        progress: (@Sendable (TransferProgress) async -> Void)?) async throws {
        guard file.path.hasPrefix("/"), !file.path.utf8.contains(0) else {
            throw HubError.message("手机文件路径无效。")
        }
        let path = Shell.quote(file.path)
        let source = try await downloadSource(serial: serial, path: path)
        try Task.checkCancellation()
        let handle = try checkpoint.openPayload()
        defer { try? handle.close() }
        guard source.size == file.size else {
            try handle.truncate(atOffset: 0)
            throw HubError.message("手机文件大小已变化。请刷新目录并重新下载。")
        }

        let record = Data((file.path + "\0" + source.stamp).utf8)
        let storedRecord = try? Data(contentsOf: checkpoint.sourceRecord)
        var offset = checkpoint.savedBytes
        if automatic, let storedRecord, storedRecord != record {
            throw HubError.message("手机源文件已变化。请检查文件后手动重试。")
        }
        if storedRecord != record || offset > source.size {
            try handle.truncate(atOffset: 0)
            try record.write(to: checkpoint.sourceRecord, options: .atomic)
            offset = 0
        }
        try handle.seek(toOffset: UInt64(offset))
        if offset < source.size {
            let start = offset + 1  // tail uses one-based byte positions.
            try await transfer(total: source.size, startingAt: offset, progress: progress, interval: .milliseconds(250),
                               measure: { checkpoint.savedBytes }) {
                _ = try await self.shell(serial: serial, script: "tail -c +\(start) -- \(path)", timeout: 3600, output: handle)
            }
        }
        guard checkpoint.savedBytes == source.size else {
            throw HubError.message("下载未收到预期的字节数，重试可继续下载。")
        }

        try Task.checkCancellation()
        await progress?(.verifying(total: source.size))
        try Task.checkCancellation()
        async let localDigest = Self.sha256(handle)
        let remoteDigest = try await shell(serial: serial, script: "sha256sum < \(path)", timeout: 3600)
        let expected = String(decoding: remoteDigest, as: UTF8.self).split(whereSeparator: \.isWhitespace).first
        guard let expected, expected.utf8.count == 64, expected.allSatisfy(\.isHexDigit) else {
            throw HubError.message("手机没有返回有效的 SHA-256 校验值，请重试。")
        }
        let current = try await downloadSource(serial: serial, path: path)
        let digest = try await localDigest
        try Task.checkCancellation()
        guard current.stamp == source.stamp, digest == expected.lowercased() else {
            try handle.truncate(atOffset: 0)
            throw HubError.message("文件完整性校验失败，可能是手机源文件已变化或下载数据损坏。请重试下载。")
        }
        try handle.synchronize()
        try Task.checkCancellation()
        await progress?(.committing(total: source.size))
        try await beforeCommit?()
        try Task.checkCancellation()
        try commitDownload(checkpoint.payload, to: destination, replaceExisting: replaceExisting)
        try? checkpoint.removeDirectory()
    }

    private func downloadSource(serial: String, path: String) async throws -> (size: Int64, stamp: String) {
        let data = try await shell(serial: serial, script: """
            [ -f \(path) ] || { echo '手机源文件不存在或已移动。' >&2; exit 1; }
            stat -Lc '%d:%i:%s:%y:%z' -- \(path)
            """)
        let stamp = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        let fields = stamp.split(separator: ":", maxSplits: 3)
        guard fields.count == 4, let size = Int64(fields[2]), size >= 0 else {
            throw HubError.message("无法确认手机源文件信息。请刷新目录后重试。")
        }
        return (size, stamp)
    }

    static func sha256(_ handle: FileHandle) async throws -> String {
        try handle.seek(toOffset: 0)
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
