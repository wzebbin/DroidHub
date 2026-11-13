import Foundation

public actor GalleryManifestCache {
    public static let shared = GalleryManifestCache(directory: URL.cachesDirectory
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.droidhub.mac", isDirectory: true)
        .appendingPathComponent("GalleryManifest-v1", isDirectory: true))

    public struct Key: Sendable {
        let filename: String

        public init?(device: String, user: Int, videos: Bool) {
            guard user >= 0, device.utf8.count == 64,
                  device.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
            filename = "\(device)-\(user)-\(videos ? "videos" : "photos").json"
        }
    }

    private let directory: URL
    private let maxBytes = 32 * 1024 * 1024

    public init(directory: URL) {
        self.directory = directory
    }

    public func read(_ key: Key) -> [MediaItem]? {
        let url = directory.appendingPathComponent(key.filename)
        guard !Task.isCancelled,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([MediaItem].self, from: data)
    }

    public func save(_ items: [MediaItem], for key: Key) {
        guard !Task.isCancelled, let data = try? JSONEncoder().encode(items),
              data.count <= maxBytes, !Task.isCancelled else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(key.filename), options: .atomic)
        } catch {
            // A cache write failure does not affect the live gallery.
        }
    }
}
