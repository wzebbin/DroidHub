import Foundation

public struct UploadCleanupError: LocalizedError {
    public let temporaryPath: String
    public let serial: String
    public let transferError: Error

    public var errorDescription: String? {
        "上传临时项目尚未确认清理：「\(temporaryPath)」。重新连接原手机后重试，队列会先尝试清理。"
    }
}

public struct FolderTransferProgress: Codable, Equatable, Sendable {
    public let completedFiles: Int
    public let totalFiles: Int
    public let currentFile: String?
}

public enum TransferProgress: Sendable {
    case transferring(bytes: Int64, total: Int64)
    case folder(FolderTransferProgress, bytes: Int64, total: Int64)
    case verifying(total: Int64)
    case committing(total: Int64)
}

public struct ADBClient: Sendable {
    private static let hardwareSerialScript = "getprop ro.serialno\ngetprop ro.boot.serialno"
    public let executable: String
    public init(executable: String) { self.executable = executable }

    public static func bundledTool(_ name: String) -> String? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    public static func discover(_ name: String) -> String? {
        if let path = bundledTool(name) { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            name == "adb" ? home + "/Library/Android/sdk/platform-tools/adb" : nil,
            "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func devices(timeout: TimeInterval = 30) async throws -> [AndroidDevice] {
        let data = try await ProcessRunner.run(executable, ["devices", "-l"], timeout: timeout)
        return AndroidDevice.parse(String(decoding: data, as: UTF8.self))
    }

    public func hardwareSerial(for serial: String) async throws -> String? {
        let data = try await shell(serial: serial, script: Self.hardwareSerialScript, timeout: 5)
        return Self.validHardwareSerial(String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline))
    }

    public func hardwareSerial(for device: AndroidDevice) async throws -> String? {
        let data = try await shell(device: device, script: Self.hardwareSerialScript, timeout: 5)
        return Self.validHardwareSerial(String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline))
    }

    public func connectionIdentity(for device: AndroidDevice) async throws -> (hardware: String?, user: Int?) {
        let script = Self.hardwareSerialScript + "\nuser=$(am get-current-user) && printf '%s\\n' \"$user\"\nexit 0"
        let data = try await shell(device: device, script: script, timeout: 5)
        try Task.checkCancellation()
        return Self.parseConnectionIdentity(data)
    }

    static func parseConnectionIdentity(_ data: Data) -> (hardware: String?, user: Int?) {
        // Keep empty property lines so the user ID can never become a hardware serial.
        let fields = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        guard fields.count >= 3 else { return (nil, nil) }
        let user = Int(fields[2].trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0 >= 0 ? $0 : nil }
        return (validHardwareSerial(fields.prefix(2)), user)
    }

    private static func validHardwareSerial(_ lines: some Sequence<Substring>) -> String? {
        lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first {
                let excluded = ["unknown", "none", "null", "1234567890", "0123456789abcdef"]
                return $0.utf8.count >= 4 && $0.utf8.count <= 128 &&
                    $0.utf8.allSatisfy { (33...126).contains($0) } &&
                    Set($0).count > 1 && !excluded.contains($0.lowercased())
            }
    }

    public func files(serial: String, path: String) async throws -> [DeviceFile] {
        let script = try Shell.directoryScript(path)
        // shell v2 preserves remote exit status and stderr; -T disables PTY conversion.
        let data = try await shell(serial: serial, script: script, timeout: 30)
        return try DeviceFile.parse(data, directory: path)
    }

    public func upload(serial: String, local: URL, directory: String, replaceExisting: Bool = false,
                       stagingID: UUID = UUID(),
                       beforeCommit: (@Sendable () async throws -> Void)? = nil,
                       progress: (@Sendable (TransferProgress) async -> Void)? = nil) async throws {
        let source = local.resolvingSymlinksInPath()
        let attributes = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard attributes.isRegularFile == true, let expectedSize = attributes.fileSize else {
            throw HubError.message("请选择要上传的普通文件。")
        }
        guard directory.hasPrefix("/"), !directory.contains("\0") else {
            throw HubError.message("手机目录路径无效。")
        }

        let staging = try uploadStagingPath(directory: directory, id: stagingID)
        let quotedStaging = Shell.quote(staging)
        let destination = (directory.hasSuffix("/") ? directory : directory + "/") + local.lastPathComponent
        let commit = uploadCommitScript(staging: quotedStaging, destination: Shell.quote(destination),
                                        size: Int64(expectedSize), replaceExisting: replaceExisting)
        try Task.checkCancellation()
        try await withUploadStaging(serial: serial, path: staging) {
            try await transfer(total: Int64(expectedSize), progress: progress, measure: {
                let data = try await self.shell(serial: serial, script: "stat -c %s -- \(quotedStaging)", timeout: 2)
                return Int64(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }) {
                _ = try await ProcessRunner.run(self.executable, ["-s", serial, "push", source.path, staging], timeout: 3600)
            }
            await progress?(.committing(total: Int64(expectedSize)))
            try await beforeCommit?()
            try Task.checkCancellation()
            _ = try await self.shell(serial: serial, script: commit)
        }
    }

    func uploadCommitScript(staging quotedStaging: String, destination quotedDestination: String,
                            size: Int64, replaceExisting: Bool) -> String {
        uploadCommitScript(staging: quotedStaging, destination: quotedDestination,
                           sizeExpression: String(size), replaceExisting: replaceExisting)
    }

    func uploadCommitScript(staging quotedStaging: String, destination quotedDestination: String,
                            sizeExpression: String, replaceExisting: Bool) -> String {
        let flags = replaceExisting ? "-T" : "-nT"
        return """
        size=$(stat -c %s -- \(quotedStaging)) || exit 1
        if [ "$size" != \(sizeExpression) ]; then
          printf '%s\\n' '手机上的临时文件大小不匹配，请重试上传。' >&2
          exit 1
        fi
        if [ -d \(quotedDestination) ]; then
          printf '%s\\n' '目标位置已有同名文件夹。请选择其他目录。' >&2
          exit 1
        fi
        if [ \(replaceExisting ? "0" : "1") = 1 ] && { [ -e \(quotedDestination) ] || [ -L \(quotedDestination) ]; }; then
          printf '%s\\n' '目标位置已有同名文件。请刷新目录后重新选择是否替换。' >&2
          exit 1
        fi
        mv \(flags) -- \(quotedStaging) \(quotedDestination) || exit 1
        if [ -e \(quotedStaging) ]; then
          printf '%s\\n' '目标位置已有同名文件。请刷新目录后重新选择是否替换。' >&2
          exit 1
        fi
        """
    }

    func shell(serial: String, script: String, timeout: TimeInterval = 15,
               output: FileHandle? = nil, inputFile: FileHandle? = nil) async throws -> Data {
        try await ProcessRunner.run(executable, ["-s", serial, "shell", "-T", "sh", "-c", Shell.quote(script)],
                                    timeout: timeout, output: output, inputFile: inputFile)
    }

    static func deviceArguments(_ device: AndroidDevice) -> [String] {
        if let transportID = device.transportID { return ["-t", transportID] }
        return ["-s", device.serial]
    }

    func shell(device: AndroidDevice, script: String, timeout: TimeInterval = 15,
               inputFile: FileHandle? = nil) async throws -> Data {
        try await ProcessRunner.run(executable, Self.deviceArguments(device) + ["shell", "-T", "sh", "-c", Shell.quote(script)],
                                    timeout: timeout, inputFile: inputFile)
    }

    public func uploadStagingPath(directory: String, id: UUID) throws -> String {
        guard directory.hasPrefix("/"), !directory.contains("\0") else {
            throw HubError.message("手机目录路径无效。")
        }
        let parent = directory.hasSuffix("/") ? directory : directory + "/"
        return parent + ".droidhub-upload-\(id.uuidString).part"
    }

    public func removeUploadStaging(serial: String, directory: String, id: UUID) async throws {
        let path = try uploadStagingPath(directory: directory, id: id)
        do {
            try await removeUploadStaging(serial: serial, path: path)
        } catch {
            throw UploadCleanupError(temporaryPath: path, serial: serial, transferError: error)
        }
    }

    private func removeUploadStaging(serial: String, path: String) async throws {
        _ = try await shell(serial: serial, script: "rm -rf -- \(Shell.quote(path))")
    }

    func withUploadStaging(serial: String, path: String, operation: () async throws -> Void) async throws {
        try Task.checkCancellation()
        do {
            try await operation()
        } catch {
            let cleaned = await Task.detached {
                do {
                    try await removeUploadStaging(serial: serial, path: path)
                    return true
                } catch { return false }
            }.value
            guard cleaned else { throw UploadCleanupError(temporaryPath: path, serial: serial, transferError: error) }
            try Task.checkCancellation()
            throw error
        }
    }

    func transfer(total: Int64, startingAt offset: Int64 = 0, progress: (@Sendable (TransferProgress) async -> Void)?,
                  interval: Duration = .milliseconds(350),
                  measure: @escaping @Sendable () async throws -> Int64?,
                  copy: @escaping @Sendable () async throws -> Void) async throws {
        if let progress {
            await progress(.transferring(bytes: offset, total: total))
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask(operation: copy)
                group.addTask {
                    var lastBytes = offset
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: interval) } catch { break }
                        if let size = try? await measure(), size > lastBytes, !Task.isCancelled {
                            lastBytes = size
                            await progress(.transferring(bytes: min(size, total), total: total))
                        }
                    }
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        } else {
            try await copy()
        }
        try Task.checkCancellation()
    }

    public func download(serial: String, remote: String, local: URL) async throws {
        _ = try await ProcessRunner.run(executable, ["-s", serial, "pull", remote, local.path], timeout: 3600)
    }
    public func downloadFile(serial: String, file: DeviceFile, destination: URL, replaceExisting: Bool,
                             checkpoint: DownloadCheckpoint? = nil,
                             automatic: Bool = false,
                             beforeCommit: (@Sendable () async throws -> Void)? = nil,
                             progress: (@Sendable (TransferProgress) async -> Void)? = nil) async throws {
        guard !file.isDirectory else { throw HubError.message("请选择要下载的文件。") }
        if replaceExisting { _ = try existingDownloadFile(at: destination) }
        if let checkpoint {
            try await resumeDownload(serial: serial, file: file, destination: destination, replaceExisting: replaceExisting,
                                     checkpoint: checkpoint, automatic: automatic,
                                     beforeCommit: beforeCommit, progress: progress)
            return
        }
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".droidhub-download-\(UUID().uuidString).part")
        defer { try? FileManager.default.removeItem(at: staging) }
        try Task.checkCancellation()
        try await transfer(total: file.size, progress: progress, interval: .milliseconds(250), measure: {
            let attributes = try FileManager.default.attributesOfItem(atPath: staging.path)
            return (attributes[.size] as? NSNumber)?.int64Value
        }) {
            try await self.download(serial: serial, remote: file.path, local: staging)
        }
        await progress?(.committing(total: file.size))
        try await beforeCommit?()
        try Task.checkCancellation()
        let size = try staging.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size.map(Int64.init) == file.size else {
            throw HubError.message("下载大小与手机文件不一致。请刷新目录后重试。")
        }
        try commitDownload(staging, to: destination, replaceExisting: replaceExisting)
    }

    func commitDownload(_ staging: URL, to destination: URL, replaceExisting: Bool) throws {
        let manager = FileManager.default
        if replaceExisting, try existingDownloadFile(at: destination) {
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: destination)
        }
    }

    private func existingDownloadFile(at destination: URL) throws -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory)
        guard !isDirectory.boolValue else {
            throw HubError.message("目标位置已有同名文件夹，请选择其他位置。")
        }
        return exists
    }

}
