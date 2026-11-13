import XCTest
import ImageIO
import CoreGraphics
@testable import DroidHubCore

private actor ImageGate {
    private(set) var calls: [(String, PhotoImagePipeline.Kind, String)] = []
    private var continuations: [CheckedContinuation<Data, Error>] = []
    private var released: Data?
    func load(client: ADBPhotoLibrary, kind: PhotoImagePipeline.Kind, id: String) async throws -> Data {
        calls.append((client.cacheID, kind, id))
        if let released { return released }
        // Deliberately ignore cancellation until release, to exercise stale completions.
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func release(_ data: Data) {
        released = data
        let pending = continuations; continuations.removeAll()
        pending.forEach { $0.resume(returning: data) }
    }
}

final class PhotoImagePipelineTests: XCTestCase {
    private func item(_ id: Int) -> MediaItem {
        MediaItem(path: "/sdcard/Pictures/\(id)/test.png", bytes: 100, modifiedAt: 1)
    }
    private func png() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    private func waitForCalls(_ gate: ImageGate, _ count: Int) async throws {
        for _ in 0..<200 {
            if await gate.calls.count >= count { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Image request did not start")
        throw CancellationError()
    }
    private func expectCancelled(_ task: Task<DecodedPhotoImage, Error>) async {
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testVideoDurationWithoutCoverSurvivesDiskCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = PhotoThumbnailDiskCache(directory: directory, availableBytes: { _ in Int.max })
        let client = ADBPhotoLibrary(adb: ADBClient(executable: "/usr/bin/false"), serial: "test", thumbnailCacheDevice: "phone")
        let video = MediaItem(path: "/sdcard/Movies/video.mp4", bytes: 42, modifiedAt: 1)
        let cold = PhotoImagePipeline(diskCache: disk) { _, _, _, _ in
            DecodedPhotoImage(videoDuration: 12.5)
        }
        _ = try await cold.image(client: client, item: video, kind: .thumbnail)
        let reopened = PhotoThumbnailDiskCache(directory: directory)
        let warm = PhotoImagePipeline(diskCache: reopened) { _, _, _, _ in
            throw HubError.message("Expected cached duration")
        }
        let hit = try await warm.image(client: client, item: video, kind: .thumbnail)
        XCTAssertNil(hit.image)
        XCTAssertEqual(hit.duration, 12.5)
    }

    func testCoalescesWaitersAndCachesEagerlyDecodedPixels() async throws {
        let gate = ImageGate(), client = ADBPhotoLibrary(adb: ADBClient(executable: "/usr/bin/false"), serial: "test-1"), media = item(1)
        let pipeline = PhotoImagePipeline { client, item, kind, pixels in
            let data = try await gate.load(client: client, kind: kind, id: item.id)
            return try PhotoImagePipeline.decode(CGImageSourceCreateWithData(data as CFData, nil), pixels: pixels)
        }
        let first = Task { try await pipeline.image(client: client, item: media, kind: .thumbnail, pixels: 128) }
        let second = Task { try await pipeline.image(client: client, item: media, kind: .thumbnail, pixels: 128) }
        try await waitForCalls(gate, 1)
        for _ in 0..<200 {
            if await pipeline.pendingConsumerCount == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let consumers = await pipeline.pendingConsumerCount
        XCTAssertEqual(consumers, 2)
        first.cancel(); await expectCancelled(first)
        await gate.release(try png())
        let result = try await second.value
        let pixels = try XCTUnwrap(result.image)
        XCTAssertEqual(pixels.width, 128)
        XCTAssertEqual(result.cost, pixels.bytesPerRow * pixels.height)
        let cached = try await pipeline.image(client: client, item: media, kind: .thumbnail, pixels: 128)
        XCTAssertTrue(result === cached)
        let calls = await gate.calls
        XCTAssertEqual(calls.count, 1)
    }
    func testBoundsThumbnailsReservesPreviewAndRemovesCancelledQueueEntry() async throws {
        let gate = ImageGate(), client = ADBPhotoLibrary(adb: ADBClient(executable: "/usr/bin/false"), serial: "test-1")
        let pipeline = PhotoImagePipeline { client, item, kind, pixels in
            let data = try await gate.load(client: client, kind: kind, id: item.id)
            return try PhotoImagePipeline.decode(CGImageSourceCreateWithData(data as CFData, nil), pixels: pixels)
        }
        let items = (1...8).map(item)
        let tasks = items.map { media in Task { try await pipeline.image(client: client, item: media, kind: .thumbnail) } }
        try await waitForCalls(gate, 2)
        let preview = Task { try await pipeline.image(client: client, item: items[0], kind: .preview) }
        try await waitForCalls(gate, 3)
        let before = await gate.calls
        XCTAssertEqual(before.filter { $0.1 == .thumbnail }.count, 2)
        XCTAssertEqual(before.filter { $0.1 == .preview }.count, 1)
        let queued = try XCTUnwrap(items.indices.first { i in !before.contains { $0.1 == .thumbnail && $0.2 == items[i].id } })
        tasks[queued].cancel(); await expectCancelled(tasks[queued])
        await gate.release(try png())
        for (index, task) in tasks.enumerated() where index != queued { _ = try await task.value }
        _ = try await preview.value
        let after = await gate.calls
        XCTAssertEqual(after.count, 8)
        XCTAssertFalse(after.contains { $0.1 == .thumbnail && $0.2 == items[queued].id })
    }
    func testInvalidationRejectsStaleWorkWithoutCancellingAnotherSession() async throws {
        let gate = ImageGate(), old = ADBPhotoLibrary(adb: ADBClient(executable: "/usr/bin/false"), serial: "test-1"), current = ADBPhotoLibrary(adb: ADBClient(executable: "/usr/bin/false"), serial: "test-2"), media = item(1)
        let pipeline = PhotoImagePipeline { client, item, kind, pixels in
            let data = try await gate.load(client: client, kind: kind, id: item.id)
            return try PhotoImagePipeline.decode(CGImageSourceCreateWithData(data as CFData, nil), pixels: pixels)
        }
        let stale = Task { try await pipeline.image(client: old, item: media, kind: .thumbnail) }
        let valid = Task { try await pipeline.image(client: current, item: media, kind: .thumbnail) }
        try await waitForCalls(gate, 2)
        await pipeline.invalidate(clientID: old.cacheID)
        await expectCancelled(stale)
        let retry = Task { try await pipeline.image(client: old, item: media, kind: .thumbnail) }
        await gate.release(try png())
        _ = try await valid.value
        _ = try await retry.value
        let calls = await gate.calls
        XCTAssertEqual(calls.filter { $0.0 == old.cacheID }.count, 2)
        XCTAssertEqual(calls.filter { $0.0 == current.cacheID }.count, 1)
    }
    func testDiskCachePersistsOnlyMatchingThumbnails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let usb = ADBPhotoLibrary(adb: ADBClient(executable: "/usr/bin/false"), serial: "usb", thumbnailCacheDevice: "phone-a")
        let wifi = ADBPhotoLibrary(adb: ADBClient(executable: "/usr/bin/false"), serial: "wifi", thumbnailCacheDevice: "phone-a")
        let other = ADBPhotoLibrary(adb: ADBClient(executable: "/usr/bin/false"), serial: "other", thumbnailCacheDevice: "phone-b")
        let unverified = ADBPhotoLibrary(adb: ADBClient(executable: "/usr/bin/false"), serial: "unverified")
        let media = item(1)
        let png = try png()
        let disk = PhotoThumbnailDiskCache(directory: directory, availableBytes: { _ in Int.max })
        let cold = PhotoImagePipeline(diskCache: disk) { _, _, _, pixels in
            try PhotoImagePipeline.decode(CGImageSourceCreateWithData(png as CFData, nil), pixels: pixels)
        }
        let first = try await cold.image(client: usb, item: media, kind: .thumbnail, pixels: 128)
        await cold.invalidate(clientID: usb.cacheID)
        let reopened = PhotoThumbnailDiskCache(directory: directory, availableBytes: { _ in Int.max })
        let warm = PhotoImagePipeline(diskCache: reopened) { _, _, _, _ in throw HubError.message("cache miss") }
        let hit = try await warm.image(client: wifi, item: media, kind: .thumbnail, pixels: 128)
        XCTAssertEqual(try XCTUnwrap(hit.image).width, try XCTUnwrap(first.image).width)
        XCTAssertEqual(hit.originalSize, first.originalSize)
        let edited = MediaItem(path: media.path, bytes: media.bytes, modifiedAt: media.modifiedAt + 1)
        for (client, item, kind, pixels) in [
            (other, media, PhotoImagePipeline.Kind.thumbnail, 128), (unverified, media, .thumbnail, 128),
            (wifi, edited, .thumbnail, 128), (wifi, media, .thumbnail, 256), (wifi, media, .preview, 128)
        ] {
            do {
                _ = try await warm.image(client: client, item: item, kind: kind, pixels: pixels)
                XCTFail("An unrelated request used the disk cache")
            } catch { XCTAssertEqual(error.localizedDescription, "cache miss") }
        }
    }

    func testDiskCacheEvictsWithinBudgetAndReleasesSpaceWhenLow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try png()
        let image = try PhotoImagePipeline.decode(CGImageSourceCreateWithData(png as CFData, nil), pixels: 128)
        let first = PhotoThumbnailDiskCache.key(device: "phone", item: item(1), pixels: 128)
        let second = PhotoThumbnailDiskCache.key(device: "phone", item: item(2), pixels: 128)
        let initial = PhotoThumbnailDiskCache(directory: directory, availableBytes: { _ in Int.max })
        await initial.insert(image, for: first)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]).first)
        let bytes = try XCTUnwrap(file.resourceValues(forKeys: [.fileSizeKey]).fileSize)

        let bounded = PhotoThumbnailDiskCache(directory: directory, byteLimit: bytes, availableBytes: { _ in Int.max })
        await bounded.insert(image, for: second)
        let evicted = await bounded.image(for: first, pixels: 128)
        let retained = await bounded.image(for: second, pixels: 128)
        XCTAssertNil(evicted)
        XCTAssertNotNil(retained)

        let lowSpace = PhotoThumbnailDiskCache(directory: directory, availableBytes: { _ in 1024 })
        await lowSpace.insert(image, for: first)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testCorruptImageDoesNotPoisonCache() async throws {
        let client = ADBPhotoLibrary(adb: ADBClient(executable: "/usr/bin/false"), serial: "test-1"), media = item(1)
        let pipeline = PhotoImagePipeline { _, _, _, pixels in
            let data = Data("not-an-image".utf8)
            return try PhotoImagePipeline.decode(CGImageSourceCreateWithData(data as CFData, nil), pixels: pixels)
        }
        for _ in 0..<2 {
            do { _ = try await pipeline.image(client: client, item: media, kind: .thumbnail); XCTFail("Expected decoding error") }
            catch { XCTAssertFalse(error is CancellationError) }
        }
    }
}
