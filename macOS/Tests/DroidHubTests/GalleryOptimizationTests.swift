import DroidHubCore
import XCTest
@testable import DroidHub

final class GalleryOptimizationTests: XCTestCase {
    func testSearchIncludesLaterPagesAndPaginatesWithoutChangingGalleryPosition() async throws {
        let items = (1...70).map { index in
            MediaItem(path: "/sdcard/Movies/Camera/clip-\(index).mp4", bytes: 1, modifiedAt: Double(71 - index))
        }
        var gallery = GalleryBrowsing()
        gallery.reload(PhotoAlbumCatalog(), videos: false, selection: [], near: nil, calendar: .current)
        gallery.reload(PhotoAlbumCatalog(photos: items), videos: true, selection: [], near: nil, calendar: .current)
        let search = try await GallerySearchResults.find("clip-70", in: gallery.searchable(in: nil))
        XCTAssertEqual(gallery.items.count, 60)
        XCTAssertEqual(search, [items[69]])
        gallery.selectAlbum("/sdcard/Movies/Camera")
        let album = gallery.album
        let matches = try await GallerySearchResults.find("CLIP-", in: gallery.searchable(in: album))
        let key = GallerySearchKey(session: UUID(), videos: true, album: album, query: "CLIP-", revision: UUID())
        var results = GallerySearchResults(key: key, matches: matches)
        XCTAssertEqual(results.visible, Array(items.prefix(60)))
        XCTAssertTrue(results.hasMore)
        results.limit += GalleryBrowsing.pageSize
        XCTAssertEqual(results.visible, items)
        XCTAssertFalse(results.hasMore)
        XCTAssertEqual(gallery.items.count, 60)
        gallery.loadMore()
        XCTAssertTrue(gallery.selectCachedKind(videos: false))
        XCTAssertTrue(gallery.selectCachedKind(videos: true))
        XCTAssertEqual(gallery.items.count, 70)
        XCTAssertEqual(gallery.album, "/sdcard/Movies/Camera")
    }

    func testCancelledSearchDoesNotReturnResults() async {
        let search = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await GallerySearchResults.find("photo", in: [])
        }
        do {
            _ = try await search.value
            XCTFail("Cancelled search returned results")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testManifestIsolatedByPhoneUserAndKindAndCanStoreAnEmptySnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = GalleryManifestCache(directory: directory)
        let phone = String(repeating: "a", count: 64)
        let key = try XCTUnwrap(GalleryManifestCache.Key(device: phone, user: 0, videos: false))
        let items = [MediaItem(path: "/sdcard/DCIM/测试.jpg", bytes: 3, modifiedAt: 1.25)]
        await cache.save(items, for: key)
        let restored = await GalleryManifestCache(directory: directory).read(key)
        XCTAssertEqual(restored, items)
        for (phone, user, videos) in [(phone, 10, false), (phone, 0, true), (String(repeating: "b", count: 64), 0, false)] {
            let other = try XCTUnwrap(GalleryManifestCache.Key(device: phone, user: user, videos: videos))
            let snapshot = await cache.read(other)
            XCTAssertNil(snapshot)
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        try Data("incomplete".utf8).write(to: try XCTUnwrap(files.first))
        let corrupted = await cache.read(key)
        XCTAssertNil(corrupted)
        await cache.save([], for: key)
        let empty = await cache.read(key)
        XCTAssertEqual(empty, [])
    }

    @MainActor
    func testGalleryRetainsSnapshotOnIdentityFailureAndClearsItOnDeviceSwitch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("adb")
        let failure = directory.appendingPathComponent("identity-failure")
        let script = #"""
        #!/bin/sh
        cd "$(dirname "$0")" || exit 1
        if [ "$1" = devices ]; then
            printf 'List of devices attached\nusb-one device model:One transport_id:11\nusb-two device model:Two transport_id:12\n'
            exit 0
        fi
        case "$7" in
            *'getprop ro.serialno'*) printf '\n\n0\n' ;;
            "'am get-current-user'")
                if [ -f identity-failure ]; then exit 1; fi
                printf '0\n' ;;
            *'for folder in '*'DCIM'*)
                if [ -f identity-failure ]; then exit 1; fi
                printf '1\00010\000/sdcard/DCIM/%s.jpg\000' "$2" ;;
            *) exit 1 ;;
        esac
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let model = HubModel(transferStorageURL: directory.appendingPathComponent("queue.json"))
        model.adbPath = executable.path

        func load() async throws {
            model.reloadMedia()
            for _ in 0..<200 {
                if !model.galleryLoading { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Gallery did not finish loading")
        }

        await model.refreshDevices()
        try await load()
        XCTAssertEqual(model.media.map(\.name), ["usb-one.jpg"])
        let originalCache = model.photoLibrary?.cacheID
        try Data().write(to: failure)
        try await load()
        XCTAssertNotNil(model.galleryNotice)
        XCTAssertEqual(model.photoLibrary?.cacheID, originalCache)
        XCTAssertEqual(model.media.map(\.name), ["usb-one.jpg"])

        try FileManager.default.removeItem(at: failure)
        model.selectedSerial = "usb-two"
        XCTAssertNil(model.photoLibrary)
        XCTAssertNil(model.galleryNotice)
        XCTAssertTrue(model.media.isEmpty)
        try await load()
        XCTAssertEqual(model.media.map(\.name), ["usb-two.jpg"])
        await model.shutdown()
    }

    @MainActor
    func testPreviewCleanupSkipsLiveSessionsAndWaitsForDownloadCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = VideoPreviewFiles(root: root)
        let second = VideoPreviewFiles(root: root)
        let abandoned = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        var started = false
        var ended = false
        let operation = Task {
            try await first.run { directory in
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                started = true
                try? await Task.sleep(for: .seconds(60))
                ended = Task.isCancelled
            }
        }
        defer { operation.cancel() }
        for _ in 0..<100 where !started { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(started)
        second.removeAbandonedSessions()
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
        await first.shutdown()
        XCTAssertTrue(ended)
        try await operation.value
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
