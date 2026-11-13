import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

actor PhotoThumbnailDiskCache {
    private struct Entry {
        let bytes: Int
        var accessed: Date
    }

    private struct Thumbnail: Codable {
        let width: Double
        let height: Double
        let png: Data?
        let duration: TimeInterval?
    }

    static let application = PhotoThumbnailDiskCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.droidhub.mac", isDirectory: true)
            .appendingPathComponent("photo-thumbnails-v1", isDirectory: true)
    )

    private let directory: URL
    private let byteLimit: Int
    private let availableBytes: @Sendable (URL) throws -> Int?
    private let fileManager = FileManager.default
    private let maximumEntryBytes = 2 * 1024 * 1024
    private var entries: [String: Entry]?
    private var totalBytes = 0

    init(directory: URL, byteLimit: Int = 256 * 1024 * 1024,
         availableBytes: @escaping @Sendable (URL) throws -> Int? = {
             try $0.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
         }) {
        self.directory = directory
        self.byteLimit = byteLimit
        self.availableBytes = availableBytes
    }

    nonisolated static func key(device: String, item: MediaItem, pixels: Int) -> String {
        let identity = [device, item.path, String(item.modifiedAt.bitPattern), String(item.bytes), String(pixels)]
        let encoded = identity.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(encoded.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func image(for key: String, pixels: Int) -> DecodedPhotoImage? {
        let name = key + ".thumb"
        let url = directory.appendingPathComponent(name)
        do {
            try loadIndex()
            guard entries?[name] != nil else { return nil }
            let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey])
            guard size.isRegularFile == true, let bytes = size.fileSize, bytes <= maximumEntryBytes,
                  let thumbnail = try? PropertyListDecoder().decode(Thumbnail.self, from: Data(contentsOf: url)) else {
                remove(name)
                return nil
            }
            let result: DecodedPhotoImage
            if let png = thumbnail.png {
                guard thumbnail.width.isFinite, thumbnail.width > 0, thumbnail.height.isFinite, thumbnail.height > 0,
                      let source = CGImageSourceCreateWithData(png as CFData, nil),
                      let image = try PhotoImagePipeline.decode(source, pixels: pixels).image else {
                    remove(name)
                    return nil
                }
                result = DecodedPhotoImage(image: image, originalSize: CGSize(width: thumbnail.width, height: thumbnail.height),
                                           duration: thumbnail.duration)
            } else {
                result = DecodedPhotoImage(videoDuration: thumbnail.duration)
            }
            let now = Date()
            entries?[name]?.accessed = now
            if now.timeIntervalSince(size.contentModificationDate ?? .distantPast) >= 60 {
                try? fileManager.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
            }
            return result
        } catch {
            remove(name)
            return nil
        }
    }

    func insert(_ image: DecodedPhotoImage, for key: String) {
        guard !Task.isCancelled else { return }
        do {
            try loadIndex()
            guard let capacity = try availableBytes(directory) else { return }
            let reserve = 512 * 1024 * 1024
            if capacity < reserve {
                trim(to: 0)
                return
            }
            var png: Data?
            if let pixels = image.image {
                let buffer = NSMutableData()
                guard let encoder = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil) else { return }
                CGImageDestinationAddImage(encoder, pixels, nil)
                guard CGImageDestinationFinalize(encoder) else { return }
                png = buffer as Data
            }
            let thumbnail = Thumbnail(width: image.originalSize.width, height: image.originalSize.height, png: png,
                                      duration: image.duration)
            let plist = PropertyListEncoder()
            plist.outputFormat = .binary
            let data = try plist.encode(thumbnail)
            guard !Task.isCancelled, data.count <= min(maximumEntryBytes, byteLimit, capacity - reserve) else { return }

            let name = key + ".thumb"
            let url = directory.appendingPathComponent(name)
            let replacedBytes = entries?[name]?.bytes ?? 0
            trim(to: byteLimit - data.count + replacedBytes, preserving: name)
            guard totalBytes - replacedBytes + data.count <= byteLimit else { return }
            try data.write(to: url, options: .atomic)
            entries?[name] = Entry(bytes: data.count, accessed: Date())
            totalBytes += data.count - replacedBytes
        } catch {
            // The original thumbnail remains available from the in-memory pipeline.
        }
    }

    private func loadIndex() throws {
        guard entries == nil else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        var index: [String: Entry] = [:]
        for file in files where file.pathExtension == "thumb" {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let bytes = values.fileSize else { continue }
            index[file.lastPathComponent] = Entry(bytes: bytes, accessed: values.contentModificationDate ?? .distantPast)
        }
        entries = index
        totalBytes = index.values.reduce(0) { $0 + $1.bytes }
        trim(to: byteLimit)
    }

    private func trim(to limit: Int, preserving protected: String? = nil) {
        guard totalBytes > limit, let entries else { return }
        for (name, _) in entries.sorted(by: { $0.value.accessed < $1.value.accessed }) where name != protected {
            remove(name)
            if totalBytes <= limit { break }
        }
    }

    private func remove(_ name: String) {
        do { try fileManager.removeItem(at: directory.appendingPathComponent(name)) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
        catch { return }
        if let entry = entries?.removeValue(forKey: name) { totalBytes -= entry.bytes }
    }
}
