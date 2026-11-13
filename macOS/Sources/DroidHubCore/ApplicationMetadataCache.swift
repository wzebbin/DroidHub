import Foundation

public actor ApplicationMetadataCache {
    public static let shared = ApplicationMetadataCache(directory: URL.cachesDirectory
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.droidhub.mac", isDirectory: true)
        .appendingPathComponent("ApplicationMetadata-v1", isDirectory: true))

    private let directory: URL
    private let maxBytes = 24 * 1024 * 1024

    public init(directory: URL) {
        self.directory = directory
    }

    public func read(device: String, user: Int) -> [String: AndroidApplication] {
        guard let url = cacheURL(device: device, user: user),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxBytes,
              let data = try? Data(contentsOf: url),
              let entries = try? PropertyListDecoder().decode([String: AndroidApplication].self, from: data) else { return [:] }
        return entries.filter { $0.key == $0.value.package && $0.value.metadataStamp != nil }
    }

    public func save(_ list: AndroidApplicationList, device: String, previous: [String: AndroidApplication]) {
        guard !Task.isCancelled, let url = cacheURL(device: device, user: list.user) else { return }
        let entries = Dictionary(uniqueKeysWithValues: list.applications.compactMap { app -> (String, AndroidApplication)? in
            guard let stamp = app.metadataStamp else { return nil }
            return (app.package, AndroidApplication(package: app.package, isSystem: app.isSystem,
                name: app.name, iconPNG: app.iconPNG, version: app.version, apkBytes: app.apkBytes,
                metadataStamp: stamp, details: app.details))
        })
        guard entries != previous else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(entries), data.count <= maxBytes else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
    }

    private func cacheURL(device: String, user: Int) -> URL? {
        guard user >= 0, device.utf8.count == 64,
              device.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return directory.appendingPathComponent("\(device)-\(user).plist")
    }
}
