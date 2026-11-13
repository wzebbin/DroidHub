import Foundation

actor PhotoOriginalDownloads {
    final class Original: Sendable {
        let file: URL
        private let directory: URL

        init() throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("droidhub-photo-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            self.directory = directory
            self.file = directory.appendingPathComponent("original")
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private struct Key: Hashable {
        let clientID: String
        let item: MediaItem
    }

    private struct Download {
        let task: Task<Original, Error>
        var readers: Set<UUID>
    }

    private var downloads: [Key: Download] = [:]

    func acquire(client: ADBPhotoLibrary, item: MediaItem) async throws -> Original {
        try Task.checkCancellation()
        let key = Key(clientID: client.cacheID, item: item)
        let reader = UUID()
        let task: Task<Original, Error>
        if var download = downloads[key] {
            download.readers.insert(reader)
            downloads[key] = download
            task = download.task
        } else {
            task = Task.detached {
                try Task.checkCancellation()
                let original = try Original()
                try await client.download(item, to: original.file)
                return original
            }
            downloads[key] = Download(task: task, readers: [reader])
        }
        defer { release(key, reader: reader) }
        return try await withTaskCancellationHandler {
            let original = try await task.value
            try Task.checkCancellation()
            return original
        } onCancel: {
            Task { await self.release(key, reader: reader) }
        }
    }

    private func release(_ key: Key, reader: UUID) {
        guard var download = downloads[key], download.readers.remove(reader) != nil else { return }
        if download.readers.isEmpty {
            downloads[key] = nil
            download.task.cancel()
        } else {
            downloads[key] = download
        }
    }
}
