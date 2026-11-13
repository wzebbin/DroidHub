import Foundation
import CoreGraphics
import ImageIO

/// Immutable thumbnail pixels and metadata. Videos can have metadata without a decodable frame.
public final class DecodedPhotoImage: NSObject, @unchecked Sendable {
    public let image: CGImage?
    public let originalSize: CGSize
    public let duration: TimeInterval?
    let cacheable: Bool
    public var cost: Int { image.map { $0.bytesPerRow * $0.height } ?? 0 }
    public init(image: CGImage, originalSize: CGSize, duration: TimeInterval? = nil) {
        self.image = image
        self.originalSize = originalSize
        self.duration = duration
        self.cacheable = true
    }

    init(videoDuration: TimeInterval?, cacheable: Bool = true) {
        self.image = nil
        self.originalSize = .zero
        self.duration = videoDuration
        self.cacheable = cacheable
    }
}

/// Bounds both network work and decoding; previews have a reserved slot.
public actor PhotoImagePipeline {
    public enum Kind: String, Sendable { case thumbnail, preview }
    public typealias Loader = @Sendable (ADBPhotoLibrary, MediaItem, Kind, Int) async throws -> DecodedPhotoImage
    public static let shared = PhotoImagePipeline(diskCache: .application)
    private struct Job {
        let id = UUID()
        let client: ADBPhotoLibrary
        let kind: Kind
        let item: MediaItem
        let pixels: Int
        var waiters: [UUID: CheckedContinuation<DecodedPhotoImage, Error>] = [:]
        var task: Task<Void, Never>?
    }
    private let thumbnails = NSCache<NSString, DecodedPhotoImage>()
    private let previews = NSCache<NSString, DecodedPhotoImage>()
    private var jobs: [String: Job] = [:]
    private var queue: [String] = []
    private var activeThumbnails = 0
    private var activePreviews = 0
    private let loader: Loader
    private let diskCache: PhotoThumbnailDiskCache?

    public init(loader: Loader? = nil) {
        self.init(diskCache: nil, loader: loader)
    }

    init(diskCache: PhotoThumbnailDiskCache?, loader: Loader? = nil) {
        self.diskCache = diskCache
        thumbnails.totalCostLimit = 64 * 1024 * 1024; thumbnails.countLimit = 256
        previews.totalCostLimit = 96 * 1024 * 1024; previews.countLimit = 6
        let originals = PhotoOriginalDownloads()
        self.loader = loader ?? { client, item, kind, pixels in
            if item.isVideo { return try await VideoThumbnail.load(client: client, item: item, pixels: pixels) }
            if kind == .thumbnail, item.bytes > Int64(JPEGEmbeddedThumbnail.prefixBytes),
               ["jpg", "jpeg"].contains((item.name as NSString).pathExtension.lowercased()) {
                let prefix = try? await client.photoPrefix(item, count: JPEGEmbeddedThumbnail.prefixBytes)
                try Task.checkCancellation()
                if let prefix, let embedded = JPEGEmbeddedThumbnail.decode(prefix: prefix, pixels: pixels) {
                    return embedded
                }
            }
            let original = try await originals.acquire(client: client, item: item)
            return try withExtendedLifetime(original) {
                try Self.decode(CGImageSourceCreateWithURL(original.file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                                pixels: pixels)
            }
        }
    }
    public func image(client: ADBPhotoLibrary, item: MediaItem, kind: Kind, pixels: Int = 320) async throws -> DecodedPhotoImage {
        try Task.checkCancellation()
        let size = kind == .preview ? 1920 : min(320, max(64, ((pixels + 63) / 64) * 64))
        let key = "\(client.cacheID)/\(kind.rawValue)/\(item.id)/\(item.modifiedAt)/\(item.bytes)/\(size)"
        if let image = cache(kind).object(forKey: key as NSString) { return image }
        let waiter = UUID()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if var job = jobs[key] {
                    job.waiters[waiter] = continuation; jobs[key] = job
                } else {
                    var job = Job(client: client, kind: kind, item: item, pixels: size)
                    job.waiters[waiter] = continuation; jobs[key] = job; queue.append(key)
                }
                pump()
            }
        }, onCancel: { Task { await self.cancel(key: key, waiter: waiter) } })
    }
    var pendingConsumerCount: Int { jobs.values.reduce(0) { $0 + $1.waiters.count } }

    public func invalidate(clientID: String) {
        let keys = jobs.filter { $0.value.client.cacheID == clientID }.map(\.key)
        for key in keys {
            guard let job = jobs.removeValue(forKey: key) else { continue }
            job.task?.cancel()
            job.waiters.values.forEach { $0.resume(throwing: CancellationError()) }
        }
        queue.removeAll { keys.contains($0) }
        thumbnails.removeAllObjects(); previews.removeAllObjects()
    }
    private func cache(_ kind: Kind) -> NSCache<NSString, DecodedPhotoImage> { kind == .thumbnail ? thumbnails : previews }
    private func cancel(key: String, waiter: UUID) {
        guard var job = jobs[key], let continuation = job.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        if job.waiters.isEmpty {
            job.task?.cancel(); jobs.removeValue(forKey: key); queue.removeAll { $0 == key }
        } else { jobs[key] = job }
    }
    private func pump() {
        while let index = queue.firstIndex(where: { key in
            guard let job = jobs[key] else { return false }
            return job.kind == .preview ? activePreviews < 1 : activeThumbnails < 2
        }) {
            let key = queue.remove(at: index)
            guard var job = jobs[key] else { continue }
            let id = job.id, kind = job.kind, client = job.client, item = job.item, pixels = job.pixels, loader = loader
            let diskCache = kind == .thumbnail ? self.diskCache : nil
            if kind == .preview { activePreviews += 1 } else { activeThumbnails += 1 }
            job.task = Task.detached(priority: kind == .preview ? .userInitiated : .utility) {
                let result: Result<DecodedPhotoImage, Error>
                do {
                    let value: DecodedPhotoImage
                    if let diskCache, let device = client.thumbnailCacheDevice {
                        let diskKey = PhotoThumbnailDiskCache.key(device: device, item: item, pixels: pixels)
                        if let cached = await diskCache.image(for: diskKey, pixels: pixels) {
                            value = cached
                        } else {
                            try Task.checkCancellation()
                            value = try await loader(client, item, kind, pixels)
                            try Task.checkCancellation()
                            if value.cacheable { await diskCache.insert(value, for: diskKey) }
                        }
                    } else {
                        value = try await loader(client, item, kind, pixels)
                    }
                    try Task.checkCancellation()
                    result = .success(value)
                } catch { result = .failure(error) }
                await self.finish(key: key, id: id, kind: kind, result: result)
            }
            jobs[key] = job
        }
    }
    private func finish(key: String, id: UUID, kind: Kind, result: Result<DecodedPhotoImage, Error>) {
        if kind == .preview { activePreviews -= 1 } else { activeThumbnails -= 1 }
        if let job = jobs[key], job.id == id {
            jobs.removeValue(forKey: key)
            if case let .success(value) = result, value.cacheable {
                cache(kind).setObject(value, forKey: key as NSString, cost: value.cost)
            }
            job.waiters.values.forEach { $0.resume(with: result) }
        }
        pump()
    }
    nonisolated static func decode(_ source: CGImageSource?, pixels: Int) throws -> DecodedPhotoImage {
        try autoreleasepool {
            guard let source,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixels,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw HubError.message("照片格式无法预览，仍可尝试导出原图。") }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? image.width
            let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? image.height
            let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
            let size = (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
            return DecodedPhotoImage(image: image, originalSize: size)
        }
    }
}
