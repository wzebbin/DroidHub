import Darwin
import Foundation

@MainActor
final class VideoPreviewFiles {
    private let root: URL
    private let files = FileManager.default
    private var session: (directory: URL, lock: FileHandle)?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var isShuttingDown = false

    init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("io.droidhub.mac-video-previews")) {
        self.root = root
    }

    nonisolated func removeAbandonedSessions() {
        let files = FileManager.default
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              let directories = try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for directory in directories where UUID(uuidString: directory.lastPathComponent) != nil {
            guard let lock = try? Self.lockDirectory(directory) else { continue }
            try? files.removeItem(at: directory)
            try? lock.close()
        }
    }

    func run(operation: @escaping @MainActor (URL) async -> Void) async throws {
        try Task.checkCancellation()
        guard !isShuttingDown else { throw CancellationError() }
        let id = UUID()
        let directory = try sessionDirectory().appendingPathComponent(id.uuidString)
        let task = Task { await operation(directory) }
        tasks[id] = task
        defer { tasks[id] = nil }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func shutdown() async {
        isShuttingDown = true
        let pending = Array(tasks.values)
        pending.forEach { $0.cancel() }
        for task in pending { await task.value }
        if let session {
            try? files.removeItem(at: session.directory)
            try? session.lock.close()
            self.session = nil
        }
    }

    private func sessionDirectory() throws -> URL {
        if let session { return session.directory }
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: attributes)
        let id = UUID().uuidString
        let staging = root.appendingPathComponent(".new-" + id)
        let directory = root.appendingPathComponent(id)
        try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: attributes)
        defer { try? files.removeItem(at: staging) }
        // Publish only after locking, so another instance never sweeps a session being created.
        let lock = try Self.lockDirectory(staging)
        try files.moveItem(at: staging, to: directory)
        session = (directory, lock)
        return directory
    }

    nonisolated private static func lockDirectory(_ directory: URL) throws -> FileHandle {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EWOULDBLOCK) }
        return handle
    }
}
