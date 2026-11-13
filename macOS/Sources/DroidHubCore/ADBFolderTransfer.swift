import Foundation
import Darwin
import CryptoKit

private struct FolderManifest: Equatable {
    enum Entry: Equatable {
        case directory
        case file(Int64)
    }

    var entries: [String: Entry] = [:]

    var directories: [String] {
        entries.compactMap { $0.value == .directory ? $0.key : nil }
    }

    var bytes: Int64 {
        entries.values.reduce(0) { total, entry in
            if case .file(let size) = entry { return total + size }
            return total
        }
    }

    var files: [String] {
        entries.compactMap { path, entry in
            if case .file = entry { return path }
            return nil
        }.sorted()
    }

    var structureDigest: String {
        var hash = SHA256()
        for path in entries.keys.sorted() {
            hash.update(data: Data(path.utf8))
            switch entries[path] {
            case .directory: hash.update(data: Data("\0d\0".utf8))
            case .file(let size): hash.update(data: Data("\0f\(size)\0".utf8))
            case nil: continue
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    mutating func add(_ entry: Entry, path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              entries.updateValue(entry, forKey: path) == nil else {
            throw HubError.message("文件夹内存在无法区分或无效的文件路径。")
        }
    }

    static func local(_ root: URL) throws -> Self {
        guard let resolved = realpath(root.path, nil) else { throw HubError.message("无法读取文件夹。") }
        defer { free(resolved) }
        let directory = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var failure: Error?
        guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys),
                                                            errorHandler: { _, error in failure = error; return false }) else {
            throw HubError.message("无法读取文件夹。")
        }
        let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        var result = Self()
        for case let item as URL in iterator {
            try Task.checkCancellation()
            let values = try item.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else {
                throw HubError.message("文件夹内含有符号链接，无法传输：\(item.lastPathComponent)")
            }
            let entry: Entry
            if values.isDirectory == true { entry = .directory }
            else if values.isRegularFile == true, let size = values.fileSize { entry = .file(Int64(size)) }
            else { throw HubError.message("文件夹内含有不支持的文件：\(item.lastPathComponent)") }
            guard item.path.hasPrefix(prefix) else { throw HubError.message("文件夹路径已变化，请重试。") }
            try result.add(entry, path: String(item.path.dropFirst(prefix.count)))
        }
        if let failure { throw failure }
        return result
    }

    static func remote(_ data: Data) throws -> Self {
        guard !data.isEmpty else { return Self() }
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.count % 3 == 1, fields.last?.isEmpty == true else {
            throw HubError.message("手机返回的文件夹清单不完整。")
        }
        var result = Self()
        for index in stride(from: 0, to: fields.count - 1, by: 3) {
            guard let path = String(bytes: fields[index + 2], encoding: .utf8), !path.isEmpty else {
                throw HubError.message("文件夹包含无法读取的文件名。")
            }
            let entry: Entry
            switch fields[index].first {
            case 100: entry = .directory
            case 45, 102:
                guard let size = Int64(String(decoding: fields[index + 1], as: UTF8.self)), size >= 0 else {
                    throw HubError.message("无法读取手机文件大小。")
                }
                entry = .file(size)
            default: throw HubError.message("文件夹内含有符号链接或特殊文件，无法传输：\(path)")
            }
            try result.add(entry, path: path)
        }
        return result
    }
}

private enum FolderLocation: Sendable {
    case mac(URL)
    case phone(String)

    func child(_ path: String) -> Self {
        switch self {
        case .mac(let root): return .mac(root.appendingPathComponent(path))
        case .phone(let root): return .phone(root + "/" + path)
        }
    }
}

private struct FolderDigest {
    static let minimumReuseSize: Int64 = 4 * 1024 * 1024

    let value: String
    let stamp: String?

    // Coarse or unavailable change times cannot distinguish same-size edits reliably.
    static func localStamp(_ info: stat) -> String? {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_ino != 0,
              info.st_ctimespec.tv_nsec > 0 else { return nil }
        return [String(info.st_dev), String(info.st_ino), String(info.st_size),
                String(info.st_mtimespec.tv_sec), String(info.st_mtimespec.tv_nsec),
                String(info.st_ctimespec.tv_sec), String(info.st_ctimespec.tv_nsec)].joined(separator: "|")
    }

    static func remoteStamp(_ stamp: Substring) -> String? {
        let fields = stamp.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 5, UInt64(fields[0]) != nil, let inode = UInt64(fields[1]), inode > 0,
              let size = Int64(fields[2]), size >= 0, !fields[3].isEmpty,
              let dot = fields[4].lastIndex(of: "."),
              let fraction = fields[4][fields[4].index(after: dot)...].split(separator: " ").first,
              fraction.count == 9, let nanoseconds = UInt32(fraction), nanoseconds > 0 else { return nil }
        return String(stamp)
    }
}

private struct FolderFile {
    let path: String
    let size: Int64

    static let batchBytes: Int64 = 16 * 1024 * 1024
    static let batchCount = 64
    static let batchCommandBytes = 10_000
}

private func folderStageName(_ id: UUID) -> String { ".droidhub-folder-\(id.uuidString).part" }

public struct FolderDownloadCheckpoint: Sendable {
    fileprivate let root: URL

    public init(destination: URL, id: UUID) {
        root = destination.deletingLastPathComponent().appendingPathComponent(folderStageName(id), isDirectory: true)
    }

    fileprivate func lock() throws -> FileHandle {
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw HubError.message("上次下载仍在使用临时文件夹，请稍后重试。")
        }
        return handle
    }

    public func discard() throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let handle = try lock()
        defer { try? handle.close() }
        try FileManager.default.removeItem(at: root)
    }
}

extension ADBClient {
    public static func uploadFolderStagingPath(directory: String, id: UUID) -> String {
        directory + (directory.hasSuffix("/") ? "" : "/") + folderStageName(id)
    }

    public func uploadFolder(serial: String, local: URL, directory: String, checkpointID: UUID? = nil,
                             automatic: Bool = false,
                             beforeCommit: (@Sendable () async throws -> Void)? = nil,
                             progress: @escaping @Sendable (TransferProgress) async -> Void) async throws {
        guard directory.hasPrefix("/"), !directory.utf8.contains(0), !local.lastPathComponent.isEmpty else {
            throw HubError.message("文件夹路径无效。")
        }
        let id = checkpointID ?? UUID()
        let parent = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        let stage = Self.uploadFolderStagingPath(directory: directory, id: id)
        let target = Shell.quote(parent + "/" + local.lastPathComponent)
        let tree = stage + "/tree", parts = stage + "/parts"
        let lock = try UploadCheckpoint(directory: directory, id: id).lockStage
        let source = local.resolvingSymlinksInPath().standardizedFileURL
        do {
            _ = try await shell(serial: serial, script: """
                set -e
                \(lock)
                if [ -e \(target) ] || [ -L \(target) ]; then
                  echo '手机上已存在同名项目。请改名后重试。' >&2; exit 1
                fi
                for dir in \(Shell.quote(stage)) \(Shell.quote(tree)) \(Shell.quote(parts)); do
                  [ ! -L "$dir" ] && mkdir -p -- "$dir" || exit 1
                done
                """)
            try await transferFolder(serial: serial, source: .mac(source), tree: .phone(tree),
                                     parts: .phone(parts), id: id, automatic: automatic, progress: progress)
            try await beforeCommit?()
            try Task.checkCancellation()
            _ = try await shell(serial: serial, script: """
                set -e
                \(lock)
                mv -nT -- \(Shell.quote(tree)) \(target)
                if [ -e \(Shell.quote(tree)) ]; then
                  echo '手机上已存在同名项目。请改名后重试。' >&2; exit 1
                fi
                rm -rf -- \(Shell.quote(stage)) || :
                """)
        } catch {
            if checkpointID == nil {
                _ = try? await Task.detached { try await discardUploadedFolder(serial: serial, directory: directory, id: id) }.value
            }
            throw error
        }
    }

    public func discardUploadedFolder(serial: String, directory: String, id: UUID) async throws {
        let lock = try UploadCheckpoint(directory: directory, id: id).lockStage
        let stage = Self.uploadFolderStagingPath(directory: directory, id: id)
        _ = try await shell(serial: serial, script: "set -e\n\(lock)\nrm -rf -- \(Shell.quote(stage))")
    }

    public func downloadFolder(serial: String, remote: String, destination: URL, checkpointID: UUID? = nil,
                               automatic: Bool = false,
                               beforeCommit: (@Sendable () async throws -> Void)? = nil,
                               progress: @escaping @Sendable (TransferProgress) async -> Void) async throws {
        let id = checkpointID ?? UUID()
        let checkpoint = FolderDownloadCheckpoint(destination: destination, id: id)
        let manager = FileManager.default
        try manager.createDirectory(at: checkpoint.root, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let lock = try checkpoint.lock()
        defer {
            if checkpointID == nil { try? manager.removeItem(at: checkpoint.root) }
            try? lock.close()
        }
        let tree = checkpoint.root.appendingPathComponent("tree", isDirectory: true)
        let parts = checkpoint.root.appendingPathComponent("parts", isDirectory: true)
        for directory in [tree, parts] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink == false else {
                throw HubError.message("下载临时目录不可用。")
            }
        }
        try await transferFolder(serial: serial, source: .phone(remote), tree: .mac(tree),
                                 parts: .mac(parts), id: id, automatic: automatic, progress: progress)
        try await beforeCommit?()
        try Task.checkCancellation()
        try manager.moveItem(at: tree, to: destination)
        try? manager.removeItem(at: checkpoint.root)
    }

    private func transferFolder(serial: String, source: FolderLocation, tree: FolderLocation, parts: FolderLocation, id: UUID,
                                automatic: Bool,
                                progress: @escaping @Sendable (TransferProgress) async -> Void) async throws {
        let manifest = try await folderManifest(serial: serial, at: source)
        try await recordFolderStructure(serial: serial, at: parts.child("manifest"),
                                        digest: manifest.structureDigest, automatic: automatic)
        let staged = try await folderManifest(serial: serial, at: tree)
        let files = manifest.files
        let total = manifest.bytes
        let candidates = files.filter { staged.entries[$0] == manifest.entries[$0] }
        let stampPaths = Set(candidates.filter { path in
            guard case .file(let size) = manifest.entries[path] else { return false }
            return size >= FolderDigest.minimumReuseSize
        })
        async let sourceHashes = folderHashes(serial: serial, at: source, paths: candidates, recording: stampPaths)
        let stagedHashes = try await folderHashes(serial: serial, at: tree, paths: candidates, recording: stampPaths)
        let expectedHashes = try await sourceHashes
        let reusable = Set(candidates.filter { expectedHashes[$0]?.value == stagedHashes[$0]?.value })
        let stable = reusable.filter { expectedHashes[$0]?.stamp != nil && stagedHashes[$0]?.stamp != nil }
        if automatic, reusable.count != staged.files.count {
            throw HubError.message("源文件已变化或已传文件校验失败。请检查后手动重试。")
        }

        let obsolete = staged.entries.keys.filter { path in
            staged.entries[path] == .directory ? manifest.entries[path] != .directory : !reusable.contains(path)
        }.sorted { $0.utf8.count > $1.utf8.count }
        try await removeFolderEntries(serial: serial, at: tree, paths: obsolete)
        switch tree {
        case .mac(let root):
            for path in manifest.directories {
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
            }
        case .phone(let root):
            if !manifest.directories.isEmpty {
                try await createRemoteDirectories(serial: serial, paths: manifest.directories.map { root + "/" + $0 })
            }
        }

        var completed = files.reduce(Int64(0)) { sum, path in
            guard reusable.contains(path), case .file(let size) = manifest.entries[path] else { return sum }
            return sum + size
        }
        var completedFiles = reusable.count
        let totalFiles = files.count
        func reportFolder(bytes: Int64, count: Int, file: String?) -> TransferProgress {
            .folder(FolderTransferProgress(completedFiles: count, totalFiles: totalFiles, currentFile: file),
                    bytes: bytes, total: total)
        }
        await progress(reportFolder(bytes: completed, count: completedFiles, file: nil))
        let remaining = files.compactMap { path -> FolderFile? in
            guard !reusable.contains(path), case .file(let size) = manifest.entries[path] else { return nil }
            return FolderFile(path: path, size: size)
        }
        let remoteRoot: String
        switch (source, tree) {
        case (.phone(let root), _), (_, .phone(let root)): remoteRoot = root
        default: preconditionFailure("Folder transfers need a Mac and a phone")
        }

        var cursor = 0
        while cursor < remaining.count {
            try Task.checkCancellation()
            var end = cursor
            var batchBytes: Int64 = 0
            var commandBytes = 0
            while end < remaining.count, end - cursor < FolderFile.batchCount {
                let file = remaining[end]
                let argumentBytes = Shell.quote(remoteRoot + "/" + file.path).utf8.count + 64
                guard file.size <= FolderFile.batchBytes - batchBytes,
                      argumentBytes <= FolderFile.batchCommandBytes - commandBytes else { break }
                batchBytes += file.size
                commandBytes += argumentBytes
                end += 1
            }

            let first = remaining[cursor]
            await progress(reportFolder(bytes: completed, count: completedFiles, file: first.path))
            if end - cursor >= 4 {
                try await copyFolderBatch(serial: serial, files: remaining[cursor..<end], source: source,
                                          tree: tree, parts: parts, folderID: id)
                completed += batchBytes
                completedFiles += end - cursor
                cursor = end
            } else {
                let base = completed
                let current = FolderTransferProgress(completedFiles: completedFiles, totalFiles: totalFiles, currentFile: first.path)
                let report: @Sendable (TransferProgress) async -> Void = { update in
                    if case .transferring(let bytes, _) = update {
                        await progress(.folder(current, bytes: base + bytes, total: total))
                    }
                }
                try await copyFolderFile(serial: serial, from: source.child(first.path), to: tree.child(first.path), parts: parts,
                                         path: first.path, size: first.size, folderID: id, automatic: automatic, progress: report)
                completed += first.size
                completedFiles += 1
                cursor += 1
            }
            await progress(reportFolder(bytes: completed, count: completedFiles, file: nil))
        }

        await progress(.verifying(total: total))
        try Task.checkCancellation()
        guard try await folderManifest(serial: serial, at: source) == manifest,
              try await folderManifest(serial: serial, at: tree) == manifest else {
            throw HubError.message("文件夹的目录结构或文件大小在传输中发生变化。请重试。")
        }
        // Check reusable digests after hashing the files that still need full reads.
        let finalOrder = stable.isEmpty ? files : files.filter { !stable.contains($0) } + files.filter { stable.contains($0) }
        async let sourceFinal = folderHashes(serial: serial, at: source, paths: finalOrder, reusing: expectedHashes.filter { stable.contains($0.key) })
        let targetFinal = try await folderHashes(serial: serial, at: tree, paths: finalOrder, reusing: stagedHashes.filter { stable.contains($0.key) })
        let expectedFinal = try await sourceFinal
        let mismatches = files.filter { targetFinal[$0]?.value != expectedFinal[$0]?.value }
        if !mismatches.isEmpty {
            try await removeFolderEntries(serial: serial, at: tree, paths: mismatches)
            let rejectedBytes = mismatches.reduce(Int64(0)) { sum, path in
                guard case .file(let size) = manifest.entries[path] else { return sum }
                return sum + size
            }
            await progress(reportFolder(bytes: total - rejectedBytes, count: totalFiles - mismatches.count, file: nil))
            throw HubError.message("\(mismatches.count) 个文件的 SHA-256 校验失败。重试时将重新传输这些文件。")
        }
        guard try await folderManifest(serial: serial, at: source) == manifest,
              try await folderManifest(serial: serial, at: tree) == manifest else {
            throw HubError.message("校验期间目录结构发生变化。请重试。")
        }
        try Task.checkCancellation()
        await progress(.committing(total: total))
        try Task.checkCancellation()
    }

    private func copyFolderBatch(serial: String, files: ArraySlice<FolderFile>, source: FolderLocation,
                                 tree: FolderLocation, parts: FolderLocation, folderID: UUID) async throws {
        switch (source, tree, parts) {
        case (.mac(let root), .phone(let target), .phone(let scratch)):
            try await uploadSmallFiles(serial: serial, files: files, root: root, target: target, scratch: scratch, folderID: folderID)
        case (.phone(let root), .mac(let target), .mac(let scratch)):
            try await downloadSmallFiles(serial: serial, files: files, root: root, target: target, scratch: scratch)
        default: preconditionFailure("Folder transfers need a Mac and a phone")
        }
    }

    private func uploadSmallFiles(serial: String, files: ArraySlice<FolderFile>, root: URL, target: String,
                                  scratch: String, folderID: UUID) async throws {
        let manager = FileManager.default
        let local = manager.temporaryDirectory.appendingPathComponent("droidhub-folder-batch-" + UUID().uuidString)
        try manager.createDirectory(at: local, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: local) }
        var paths: [String] = []
        var commands: [String] = []
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let original = root.appendingPathComponent(file.path)
            let descriptor = open(original.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw HubError.message("无法读取待上传文件：\(file.path)") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size == file.size else {
                throw HubError.message("待上传文件已变化：\(file.path)")
            }
            let data = try handle.read(upToCount: Int(file.size) + 1) ?? Data()
            guard data.count == Int(file.size) else { throw HubError.message("待上传文件已变化：\(file.path)") }
            let temporary = local.appendingPathComponent(String(index))
            try data.write(to: temporary)
            let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
                + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
            try manager.setAttributes([.modificationDate: modified], ofItemAtPath: temporary.path)
            paths.append(temporary.path)
            commands.append("commit \"$batch/\(index)\" \(Shell.quote(target + "/" + file.path)) \(file.size)")
        }
        let batch = scratch + "/batch-" + UUID().uuidString
        let lock = try UploadCheckpoint(directory: scratch, id: folderID).lockStage
        let quotedBatch = Shell.quote(batch)
        _ = try await shell(serial: serial, script: "set -e\n\(lock)\nmkdir -- \(quotedBatch)")
        _ = try await ProcessRunner.run(executable, ["-s", serial, "push"] + paths + [batch + "/"], timeout: 120)
        try Task.checkCancellation()
        let commit = uploadCommitScript(staging: "\"$1\"", destination: "\"$2\"", sizeExpression: "\"$3\"", replaceExisting: false)
        _ = try await shell(serial: serial, script: """
            set -e
            \(lock)
            batch=\(quotedBatch)
            commit() {
                \(commit)
            }
            \(commands.joined(separator: "\n"))
            rmdir -- "$batch"
            """, timeout: 120)
    }

    private func downloadSmallFiles(serial: String, files: ArraySlice<FolderFile>, root: String, target: URL,
                                    scratch: URL) async throws {
        let manager = FileManager.default
        let batch = scratch.appendingPathComponent("batch-download")
        do { try manager.removeItem(at: batch) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
        try manager.createDirectory(at: batch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: batch) }

        // adb pull flattens remote paths into one directory. Use a separate stream for repeated basenames.
        var names = Set<String>()
        var direct: [FolderFile] = []
        var collisions: [FolderFile] = []
        for file in files {
            let leaf = (file.path as NSString).lastPathComponent
            if names.insert(leaf.precomposedStringWithCanonicalMapping.lowercased()).inserted {
                direct.append(file)
            } else {
                collisions.append(file)
            }
        }

        let pulled = batch.appendingPathComponent("pulled")
        try manager.createDirectory(at: pulled, withIntermediateDirectories: false)
        _ = try await ProcessRunner.run(executable, ["-s", serial, "pull"] + direct.map { root + "/" + $0.path }
                                        + [pulled.path + "/"], timeout: 120)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        for file in direct {
            try Task.checkCancellation()
            let temporary = pulled.appendingPathComponent((file.path as NSString).lastPathComponent)
            let values = try temporary.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  values.fileSize.map(Int64.init) == file.size else {
                throw HubError.message("下载文件不完整：\(file.path)")
            }
            try manager.moveItem(at: temporary, to: target.appendingPathComponent(file.path))
        }

        if !collisions.isEmpty {
            try await downloadCollidingFiles(serial: serial, files: collisions, root: root, target: target, batch: batch)
        }
    }

    private func downloadCollidingFiles(serial: String, files: [FolderFile], root: String, target: URL, batch: URL) async throws {
        let manager = FileManager.default
        let payload = batch.appendingPathComponent("payload")
        guard manager.createFile(atPath: payload.path, contents: nil) else {
            throw HubError.message("无法创建小文件下载临时文件。")
        }
        let handle = try FileHandle(forUpdating: payload)
        defer { try? handle.close() }
        let commands = files.map { "copy \(Shell.quote(root + "/" + $0.path)) \($0.size)" }
        _ = try await shell(serial: serial, script: """
            set -e
            copy() {
                [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %s -- "$1")" = "$2" ] &&
                    head -c "$2" -- "$1" && [ "$(stat -c %s -- "$1")" = "$2" ] ||
                    { printf '%s\\n' '待下载文件已变化或无法读取，请刷新后重试。' >&2; exit 1; }
            }
            \(commands.joined(separator: "\n"))
            """, timeout: 120, output: handle)
        try Task.checkCancellation()
        guard try handle.seekToEnd() == files.reduce(UInt64(0), { $0 + UInt64($1.size) }) else {
            throw HubError.message("小文件批次下载的字节数不一致，请重试。")
        }
        try handle.seek(toOffset: 0)
        let temporary = batch.appendingPathComponent("file")
        for file in files {
            try Task.checkCancellation()
            let data = file.size == 0 ? Data() : try handle.read(upToCount: Int(file.size)) ?? Data()
            guard data.count == Int(file.size) else { throw HubError.message("下载文件不完整：\(file.path)") }
            try data.write(to: temporary)
            try manager.moveItem(at: temporary, to: target.appendingPathComponent(file.path))
        }
    }

    private func copyFolderFile(serial: String, from source: FolderLocation, to target: FolderLocation,
                                parts: FolderLocation, path: String, size: Int64, folderID: UUID,
                                automatic: Bool,
                                progress: @escaping @Sendable (TransferProgress) async -> Void) async throws {
        let digest = Array(SHA256.hash(data: Data(path.utf8)).prefix(16))
        let id = UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                             digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
        switch (source, target, parts) {
        case (.mac(let local), .phone(let remote), .phone(let scratch)):
            if size >= UploadCheckpoint.minimumSize {
                let checkpoint = try UploadCheckpoint(directory: scratch, id: id, lockID: folderID)
                let parent = (remote as NSString).deletingLastPathComponent
                try await uploadResumable(serial: serial, local: local, directory: parent, replaceExisting: false,
                                          checkpoint: checkpoint, automatic: automatic, progress: progress)
            } else {
                let temporary = scratch + "/" + UUID().uuidString
                _ = try await ProcessRunner.run(executable, ["-s", serial, "push", local.path, temporary], timeout: 3600)
                try Task.checkCancellation()
                let commit = uploadCommitScript(staging: Shell.quote(temporary), destination: Shell.quote(remote),
                                                size: size, replaceExisting: false)
                _ = try await shell(serial: serial, script: commit)
            }
        case (.phone(let remote), .mac(let local), .mac(let scratch)):
            if size >= DownloadCheckpoint.minimumSize {
                let file = DeviceFile(name: local.lastPathComponent, path: remote, isDirectory: false, size: size)
                try await downloadFile(serial: serial, file: file, destination: local, replaceExisting: false,
                                       checkpoint: DownloadCheckpoint(parent: scratch, id: id), automatic: automatic, progress: progress)
            } else {
                let temporary = scratch.appendingPathComponent(UUID().uuidString)
                try await download(serial: serial, remote: remote, local: temporary)
                try Task.checkCancellation()
                guard let actual = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(actual) == size else {
                    throw HubError.message("下载大小与手机文件不一致：\(path)")
                }
                try FileManager.default.moveItem(at: temporary, to: local)
            }
        default: preconditionFailure("Folder transfers need a Mac and a phone")
        }
    }

    private func recordFolderStructure(serial: String, at record: FolderLocation, digest: String, automatic: Bool) async throws {
        let changed = "源文件夹结构已变化。请检查后手动重试。"
        switch record {
        case .mac(let url):
            let bytes = Data(digest.utf8)
            if automatic, let stored = try? Data(contentsOf: url), stored != bytes {
                throw HubError.message(changed)
            }
            try bytes.write(to: url, options: .atomic)
        case .phone(let path):
            let record = Shell.quote(path)
            _ = try await shell(serial: serial, script: """
                set -e
                if [ \(automatic ? "1" : "0") = 1 ] && [ -f \(record) ] && [ "$(cat \(record))" != \(digest) ]; then
                  echo \(Shell.quote(changed)) >&2; exit 1
                fi
                printf '%s' \(digest) > \(Shell.quote(path + ".new"))
                mv -f -- \(Shell.quote(path + ".new")) \(record)
                """)
        }
    }

    private func folderManifest(serial: String, at location: FolderLocation) async throws -> FolderManifest {
        switch location {
        case .mac(let root): return try FolderManifest.local(root)
        case .phone(let root): return try await remoteFolder(serial: serial, path: root)
        }
    }

    private func folderHashes(serial: String, at location: FolderLocation, paths: [String],
                              recording: Set<String> = [], reusing previous: [String: FolderDigest] = [:]) async throws -> [String: FolderDigest] {
        guard !paths.isEmpty else { return [:] }
        switch location {
        case .mac(let root):
            var hashes: [String: FolderDigest] = [:]
            for path in paths {
                try Task.checkCancellation()
                let url = root.appendingPathComponent(path)
                let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard descriptor >= 0 else { throw HubError.message("无法读取待校验文件：\(path)") }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                var info = stat()
                guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                    throw HubError.message("待校验文件已变化：\(path)")
                }
                let before = FolderDigest.localStamp(info)
                if let cached = previous[path], let stamp = cached.stamp, before == stamp {
                    hashes[path] = cached
                    continue
                }
                let digest = try await Self.sha256(handle)
                var stamp: String?
                if recording.contains(path), let before, fstat(descriptor, &info) == 0, FolderDigest.localStamp(info) == before,
                   lstat(url.path, &info) == 0, FolderDigest.localStamp(info) == before {
                    stamp = before
                }
                hashes[path] = FolderDigest(value: digest, stamp: stamp)
            }
            return hashes
        case .phone(let root):
            return try await phoneFolderHashes(serial: serial, root: root, paths: paths,
                                               recording: recording, reusing: previous)
        }
    }

    private func phoneFolderHashes(serial: String, root: String, paths: [String], recording: Set<String>,
                                   reusing previous: [String: FolderDigest]) async throws -> [String: FolderDigest] {
        var hashes: [String: FolderDigest] = [:]
        var batch: [String] = []
        let preamble = !recording.isEmpty || !previous.isEmpty ? #"""
        set -e
        stamp() {
            [ -f "$1" ] && [ ! -L "$1" ] || return 1
            stat -c '%d|%i|%s|%y|%z' -- "$1" 2>/dev/null
        }
        record() {
            before=$(stamp "$1") || before=
            hash=$(sha256sum < "$1") || exit 1
            after=$(stamp "$1") || after=
            [ "$before" = "$after" ] || before=
            printf '%s\t%s\n' "${hash%% *}" "$before"
        }
        verify() {
            current=$(stamp "$1") || current=
            if [ "$current" = "$2" ]; then
                printf '%s\t%s\n' "$3" "$current"
            else
                sha256sum < "$1"
            fi
        }

        """# : "set -e\n"
        var script = preamble
        func readBatch() async throws {
            guard !batch.isEmpty else { return }
            let data = try await shell(serial: serial, script: script, timeout: 3600)
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
            guard lines.count == batch.count else { throw HubError.message("手机返回的文件校验清单不完整。") }
            for (path, line) in zip(batch, lines) {
                let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard let digest = fields.first?.split(whereSeparator: \.isWhitespace).first,
                      digest.utf8.count == 64, digest.allSatisfy(\.isHexDigit) else {
                    throw HubError.message("手机没有返回有效的 SHA-256 校验值。")
                }
                let stamp = fields.count == 2 ? FolderDigest.remoteStamp(fields[1]) : nil
                hashes[path] = FolderDigest(value: digest.lowercased(), stamp: stamp)
            }
        }
        for path in paths {
            try Task.checkCancellation()
            let file = Shell.quote(root + "/" + path)
            let command: String
            if recording.contains(path) {
                command = "record \(file)\n"
            } else if let cached = previous[path], let stamp = cached.stamp {
                command = "verify \(file) \(Shell.quote(stamp)) \(Shell.quote(cached.value))\n"
            } else {
                command = "sha256sum < \(file)\n"
            }
            if script.utf8.count + command.utf8.count > 12_000, !batch.isEmpty {
                try await readBatch()
                batch.removeAll(keepingCapacity: true)
                script = preamble
            }
            batch.append(path)
            script += command
        }
        try await readBatch()
        return hashes
    }

    private func removeFolderEntries(serial: String, at location: FolderLocation, paths: [String]) async throws {
        for path in paths {
            try Task.checkCancellation()
            switch location.child(path) {
            case .mac(let url):
                try FileManager.default.removeItem(at: url)
            case .phone(let path):
                _ = try await shell(serial: serial, script: "rm -rf -- \(Shell.quote(path))")
            }
        }
    }

    private func remoteFolder(serial: String, path: String, timeout: TimeInterval = 90) async throws -> FolderManifest {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw HubError.message("手机文件夹路径无效。") }
        let script = #"""
        root=\#(Shell.quote(path))
        [ -d "$root" ] && [ ! -L "$root" ] || { printf '%s\n' '无法读取手机文件夹或文件夹是符号链接。' >&2; exit 1; }
        if find / -maxdepth 0 -printf '' >/dev/null 2>&1; then
            find "$root" -mindepth 1 -printf '%M\0%s\0%P\0'
        else
            find "$root" -mindepth 1 -exec sh -c '
                root=$1
                shift
                for item do
                    relative=${item#"$root"/}
                    if [ -L "$item" ]; then
                        printf "l\0%s\0%s\0" 0 "$relative"
                    elif [ -d "$item" ]; then
                        printf "d\0%s\0%s\0" 0 "$relative"
                    elif [ -f "$item" ]; then
                        size=$(stat -c %s -- "$item") || exit 1
                        printf "f\0%s\0%s\0" "$size" "$relative"
                    else
                        printf "?\0%s\0%s\0" 0 "$relative"
                    fi
                done
            ' sh "$root" {} +
        fi
        """#
        let data = try await shell(serial: serial, script: script, timeout: timeout)
        try Task.checkCancellation()
        return try FolderManifest.remote(data)
    }

    private func createRemoteDirectories(serial: String, paths: [String]) async throws {
        var command = "mkdir -p --"
        for path in paths {
            let argument = " " + Shell.quote(path)
            if command.utf8.count + argument.utf8.count > 12_000 {
                try Task.checkCancellation()
                _ = try await shell(serial: serial, script: command)
                command = "mkdir -p --"
            }
            command += argument
        }
        try Task.checkCancellation()
        _ = try await shell(serial: serial, script: command)
    }
}
