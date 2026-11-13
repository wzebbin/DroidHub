import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum VideoThumbnail {
    @MainActor
    static func load(client: ADBPhotoLibrary, item: MediaItem, pixels: Int) async throws -> DecodedPhotoImage {
        var location = URLComponents()
        location.scheme = "droidhub-video"
        location.host = "preview"
        location.path = "/" + item.name
        guard let url = location.url, item.bytes > 0 else {
            return DecodedPhotoImage(videoDuration: nil)
        }
        let asset = AVURLAsset(url: url)
        let loader = VideoRangeLoader(client: client, item: item)
        asset.resourceLoader.setDelegate(loader, queue: .main)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixels, height: pixels)
        defer { loader.cancel() }
        return try await withTaskCancellationHandler {
            let duration = (try? await asset.load(.duration).seconds).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            try Task.checkCancellation()
            do {
                let image = try await generator.image(at: .zero).image
                try Task.checkCancellation()
                return DecodedPhotoImage(image: image, originalSize: CGSize(width: image.width, height: image.height),
                                         duration: duration)
            } catch {
                try Task.checkCancellation()
                let code = (error as? AVError)?.code
                let unsupported = code == .fileFormatNotRecognized || code == .decoderNotFound
                    || code == .operationNotSupportedForAsset || code == .noImageAtTime
                let cacheable = !loader.readFailed && (unsupported || loader.hitReadLimit)
                if duration != nil || cacheable {
                    return DecodedPhotoImage(videoDuration: duration, cacheable: cacheable)
                }
                throw error
            }
        } onCancel: {
            Task { @MainActor in
                generator.cancelAllCGImageGeneration()
                loader.cancel()
            }
        }
    }
}

@MainActor
private final class VideoRangeLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let client: ADBPhotoLibrary
    private let item: MediaItem
    private var pending: [ObjectIdentifier: (AVAssetResourceLoadingRequest, Task<Void, Never>)] = [:]
    // Bound traffic for covers even if the decoder asks for the entire video.
    private var remaining = 8 * 1024 * 1024
    private var cancelled = false
    private(set) var hitReadLimit = false
    private(set) var readFailed = false

    init(client: ADBPhotoLibrary, item: MediaItem) {
        self.client = client
        self.item = item
    }

    nonisolated func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                                    shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        MainActor.assumeIsolated { start(request) }
    }

    nonisolated func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                                    didCancel request: AVAssetResourceLoadingRequest) {
        MainActor.assumeIsolated {
            pending.removeValue(forKey: ObjectIdentifier(request))?.1.cancel()
        }
    }

    private func start(_ request: AVAssetResourceLoadingRequest) -> Bool {
        guard !cancelled else { return false }
        let id = ObjectIdentifier(request)
        let task = Task {
            do {
                try await respond(to: request)
                if pending.removeValue(forKey: id) != nil { request.finishLoading() }
            } catch {
                if pending.removeValue(forKey: id) != nil { request.finishLoading(with: error) }
            }
        }
        pending[id] = (request, task)
        return true
    }

    private func respond(to request: AVAssetResourceLoadingRequest) async throws {
        if let info = request.contentInformationRequest {
            let ext = (item.name as NSString).pathExtension
            info.contentType = (UTType(filenameExtension: ext) ?? .movie).identifier
            info.contentLength = item.bytes
            info.isByteRangeAccessSupported = true
        }
        guard let data = request.dataRequest else { return }
        let initial = max(0, data.requestedOffset)
        let end = data.requestsAllDataToEndOfResource
            ? item.bytes : initial + min(Int64(data.requestedLength), max(0, item.bytes - initial))
        var offset = max(initial, data.currentOffset)
        while offset < end {
            try Task.checkCancellation()
            let count = Int(min(end - offset, 512 * 1024))
            guard count <= remaining else {
                hitReadLimit = true
                throw CocoaError(.fileReadTooLarge)
            }
            remaining -= count
            let bytes: Data
            do {
                bytes = try await client.readVideo(item, offset: offset, count: count)
            } catch {
                if !Task.isCancelled { readFailed = true }
                throw error
            }
            try Task.checkCancellation()
            data.respond(with: bytes)
            offset += Int64(bytes.count)
        }
    }

    func cancel() {
        cancelled = true
        let jobs = pending.values
        pending.removeAll()
        for (request, task) in jobs {
            task.cancel()
            request.finishLoading(with: CancellationError())
        }
    }
}
