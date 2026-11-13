import Darwin
import Foundation

public struct UploadCheckpoint: Sendable {
    public static let minimumSize = DownloadCheckpoint.minimumSize

    public let path: String
    private let lockBucket: String

    public init(directory: String, id: UUID) throws {
        try self.init(directory: directory, id: id, lockID: id)
    }

    init(directory: String, id: UUID, lockID: UUID) throws {
        guard directory.hasPrefix("/"), !directory.utf8.contains(0) else {
            throw HubError.message("手机目录路径无效。")
        }
        path = (directory.hasSuffix("/") ? directory : directory + "/") + ".droidhub-upload-resume-\(id.uuidString)"
        lockBucket = String(lockID.uuidString.prefix(2))
    }

    fileprivate var payload: String { path + "/payload.part" }
    fileprivate var variables: String {
        """
        set -e
        stage=\(Shell.quote(path))
        payload="$stage/payload.part"
        record="$stage/source"
        """
    }

    var lockStage: String {
        // Android shared storage may not implement flock. Keep a bounded set of locks on its local filesystem.
        """
        umask 077
        locks=/data/local/tmp/.droidhub-upload-locks
        mkdir -p -- "$locks"
        exec 9>>"$locks/\(lockBucket)"
        flock 0 <&9
        """
    }

    fileprivate var checkStage: String {
        """
        [ -d "$stage" ] && [ ! -L "$stage" ] && [ ! -L "$payload" ] && [ ! -L "$record" ] || exit 1
        { [ ! -e "$payload" ] || [ -f "$payload" ]; } && { [ ! -e "$record" ] || [ -f "$record" ]; } || exit 1
        """
    }
}

extension ADBClient {
    public func discardUploadCheckpoint(serial: String, checkpoint: UploadCheckpoint) async throws {
        _ = try await shell(serial: serial, script: """
            \(checkpoint.variables)
            \(checkpoint.lockStage)
            if [ ! -e "$stage" ] && [ ! -L "$stage" ]; then exit 0; fi
            \(checkpoint.checkStage)
            rm -f -- "$payload" "$record"
            rmdir -- "$stage"
            """)
    }

    public func uploadResumable(serial: String, local: URL, directory: String, replaceExisting: Bool,
                                checkpoint: UploadCheckpoint, automatic: Bool = false,
                                beforeCommit: (@Sendable () async throws -> Void)? = nil,
                                progress: @escaping @Sendable (TransferProgress) async -> Void) async throws {
        let handle = try FileHandle(forReadingFrom: local)
        defer { try? handle.close() }
        let source = try UploadSource(handle: handle)
        let total = source.size
        let destination = Shell.quote((directory.hasSuffix("/") ? directory : directory + "/") + local.lastPathComponent)
        let context = """
        \(checkpoint.variables)
        source=\(Shell.quote(source.stamp))
        """
        let locked = """
        \(context)
        \(checkpoint.lockStage)
        \(checkpoint.checkStage)
        [ "$(cat "$record")" = "$source" ] || exit 1
        """
        let offset = try await uploadOffset(serial: serial, script: """
            \(context)
            if [ \(replaceExisting ? "0" : "1") = 1 ] && { [ -e \(destination) ] || [ -L \(destination) ]; }; then
              echo '目标位置已有同名项目。请刷新目录后重新选择是否替换。' >&2
              exit 1
            fi
            \(checkpoint.lockStage)
            mkdir -p -- "$stage"
            \(checkpoint.checkStage)
            size=0
            if [ \(automatic ? "1" : "0") = 1 ] && [ -f "$record" ] && [ "$(cat "$record")" != "$source" ]; then
              echo 'Mac 源文件已变化。请检查文件后手动重试。' >&2; exit 1
            fi
            if [ -f "$record" ] && [ "$(cat "$record")" = "$source" ] && [ -f "$payload" ]; then
              size=$(stat -c %s -- "$payload")
            fi
            if [ "$size" -eq 0 ] || [ "$size" -gt \(total) ]; then
              : > "$payload"
              printf '%s\\n' "$source" > "$record"
              size=0
            fi
            printf '%s\\n' "$size"
            """)
        guard offset <= total else { throw HubError.message("手机上的上传断点无效，请重试。") }
        if offset < total {
            try handle.seek(toOffset: UInt64(offset))
            try await transfer(total: total, startingAt: offset, progress: progress, interval: .seconds(1), measure: {
                try await self.uploadOffset(serial: serial, script: "stat -c %s -- \(Shell.quote(checkpoint.payload))", timeout: 3)
            }) {
                _ = try await self.shell(serial: serial, script: """
                    \(locked)
                    [ "$(stat -c %s -- "$payload")" = \(offset) ] || exit 1
                    cat 3<&9 >> "$payload"
                    """, timeout: 3600, inputFile: handle)
            }
        }

        try Task.checkCancellation()
        let received = try await uploadOffset(serial: serial, script: "stat -c %s -- \(Shell.quote(checkpoint.payload))")
        guard received == total else {
            throw HubError.message("手机收到的字节数不完整。重试可继续上传。")
        }
        await progress(.verifying(total: total))
        try Task.checkCancellation()
        async let localDigest = Self.sha256(handle)
        let stat = "stat -c '%d:%i:%s:%y:%z' -- \"$payload\""
        let verification = try await shell(serial: serial, script: """
            \(locked)
            before=$(\(stat))
            sha256sum < "$payload"
            [ "$(\(stat))" = "$before" ]
            printf '%s\\n' "$before"
            """, timeout: 3600)
        let lines = String(decoding: verification, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard lines.count == 2, let expected = lines[0].split(whereSeparator: \.isWhitespace).first,
              expected.utf8.count == 64, expected.allSatisfy(\.isHexDigit) else {
            throw HubError.message("手机没有返回有效的 SHA-256 校验值，请重试。")
        }
        let checked = """
        \(locked)
        [ "$(\(stat))" = \(Shell.quote(String(lines[1]))) ] || exit 1
        """
        let digest = try await localDigest
        try Task.checkCancellation()
        let current = try FileHandle(forReadingFrom: local)
        defer { try? current.close() }
        let currentSource = try UploadSource(handle: current)
        guard currentSource.stamp == source.stamp, digest == expected.lowercased() else {
            _ = try await shell(serial: serial, script: """
                \(checked)
                rm -f -- "$payload" "$record"
                """)
            await progress(.transferring(bytes: 0, total: total))
            throw HubError.message("文件完整性校验失败，可能是 Mac 源文件已变化或上传数据损坏。请重试上传。")
        }
        await progress(.committing(total: total))
        try await beforeCommit?()
        try Task.checkCancellation()
        let commit = uploadCommitScript(staging: "\"$payload\"", destination: destination, size: total, replaceExisting: replaceExisting)
        _ = try await shell(serial: serial, script: """
            \(checked)
            \(commit)
            rm -f -- "$record" && rmdir -- "$stage" || :
            """)
    }

    private func uploadOffset(serial: String, script: String, timeout: TimeInterval = 15) async throws -> Int64 {
        let data = try await shell(serial: serial, script: script, timeout: timeout)
        guard let size = Int64(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)), size >= 0 else {
            throw HubError.message("无法读取手机上的上传进度。")
        }
        return size
    }
}

private struct UploadSource {
    let size: Int64
    let stamp: String

    init(handle: FileHandle) throws {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw HubError.message("请选择要上传的普通文件。")
        }
        size = info.st_size
        stamp = [
            String(info.st_dev), String(info.st_ino), String(size),
            String(info.st_mtimespec.tv_sec), String(info.st_mtimespec.tv_nsec),
            String(info.st_ctimespec.tv_sec), String(info.st_ctimespec.tv_nsec)
        ].joined(separator: ":")
    }
}
