import AVFoundation
import DroidHubCore
import XCTest
@testable import DroidHub

@MainActor
final class VideoGalleryIntegrationTests: XCTestCase {
    func testVideoGalleryOnPhoneWhenConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let adb = environment["DROIDHUB_VIDEO_ADB"],
              let usb = environment["DROIDHUB_VIDEO_USB"],
              let wifi = environment["DROIDHUB_VIDEO_WIFI"],
              let path = environment["DROIDHUB_VIDEO_FIXTURES"],
              let album = environment["DROIDHUB_VIDEO_ALBUM"] else {
            throw XCTSkip("No explicit video fixtures")
        }
        let fixtures = URL(fileURLWithPath: path)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }

        for (label, serial) in [("USB", usb), ("Wi-Fi", wifi)] {
            let folder = temporary.appendingPathComponent(label)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let model = HubModel(transferStorageURL: folder.appendingPathComponent("transfers.json"))
            model.adbPath = adb
            await model.refreshDevices()
            model.selectedSerial = serial
            try await wait { model.onlineSerial == serial }
            XCTAssertEqual(model.selectedDevice?.isWireless, label == "Wi-Fi")
            model.reloadMedia()
            try await wait { !model.galleryLoading && model.photoLibrary != nil }
            let photos = try await GallerySearchResults.find("同名.MP4", in: model.searchableMedia(in: nil))
            XCTAssertTrue(photos.isEmpty)
            model.selectGalleryVideos(true)
            try await wait { !model.galleryLoading && model.showsVideos }
            let library = try XCTUnwrap(model.photoLibrary)

            let albums = model.photoAlbums.filter { $0.name == album }
            XCTAssertEqual(Set(albums.map(\.id)), Set(["DCIM", "Movies", "Pictures"].map { "/sdcard/\($0)/\(album)" }))
            let matches = try await GallerySearchResults.find("同名.MP4", in: model.searchableMedia(in: nil)).filter { $0.path.contains("/\(album)/") }
            XCTAssertEqual(matches.count, 2)
            XCTAssertEqual(PhotoDateGroup.groups(in: matches, calendar: .current).count, 2)
            let movieAlbum = "/sdcard/Movies/\(album)"
            model.selectPhotoAlbum(movieAlbum)
            let albumMatches = try await GallerySearchResults.find("同名.MP4", in: model.searchableMedia(in: movieAlbum))
            XCTAssertEqual(albumMatches.count, 1)
            model.selectGalleryVideos(false)
            XCTAssertFalse(model.showsVideos)
            model.selectGalleryVideos(true)
            XCTAssertEqual(model.photoAlbumID, movieAlbum)
            model.reloadMedia()
            try await wait { !model.galleryLoading }
            XCTAssertEqual(model.photoAlbumID, movieAlbum)

            let thumbnailPipeline = PhotoImagePipeline()
            for (item, destination) in zip(matches, PhotoExport.destinations(for: matches, directory: folder)) {
                let movie = item.path.hasPrefix("/sdcard/Movies/")
                let thumbnail = try await thumbnailPipeline.image(client: library, item: item, kind: .thumbnail)
                XCTAssertEqual(try XCTUnwrap(thumbnail.duration), movie ? 14 : 5, accuracy: 0.3)
                XCTAssertGreaterThan(try XCTUnwrap(thumbnail.image).width, 10)
                let reference = fixtures.appendingPathComponent(movie ? "tail-index.mp4" : "playable.mp4")
                try await library.export(item, destination: destination, replaceExisting: false)
                XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: reference))
                if !movie {
                    let local = folder.appendingPathComponent("preview.mp4")
                    try await library.downloadVideo(item, to: local) { _ in }
                    let asset = AVURLAsset(url: local)
                    let playable = try await asset.load(.isPlayable)
                    XCTAssertTrue(playable)
                    let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                    try await wait { player.currentItem?.status == .readyToPlay }
                    let seeked = await player.seek(to: CMTime(seconds: 3, preferredTimescale: 600),
                                                   toleranceBefore: .zero, toleranceAfter: .zero)
                    XCTAssertTrue(seeked)
                    XCTAssertEqual(player.currentTime().seconds, 3, accuracy: 0.1)
                    player.replaceCurrentItem(with: nil)
                }
            }

            let unknownMatches = try await GallerySearchResults.find("不支持.mkv", in: model.searchableMedia(in: model.photoAlbumID))
            let unknown = try XCTUnwrap(unknownMatches.first)
            let unknownLocal = folder.appendingPathComponent(unknown.name)
            try await library.export(unknown, destination: unknownLocal, replaceExisting: false)
            XCTAssertEqual(try Data(contentsOf: unknownLocal), try Data(contentsOf: fixtures.appendingPathComponent("unsupported.mkv")))
            let unsupportedPlayable = try? await AVURLAsset(url: unknownLocal).load(.isPlayable)
            XCTAssertNotEqual(unsupportedPlayable, true)

            let largeMatches = try await GallerySearchResults.find("取消预览", in: model.searchableMedia(in: model.photoAlbumID))
            let large = try XCTUnwrap(largeMatches.first)
            let destination = folder.appendingPathComponent("cancel.mp4")
            let download = Task { try await library.downloadVideo(large, to: destination) { _ in } }
            defer { download.cancel() }
            try await waitForPartialDownload(in: folder, total: large.bytes)
            download.cancel()
            do {
                try await download.value
                XCTFail("Cancelled video unexpectedly finished")
            } catch is CancellationError { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasSuffix(".part") })
            if environment["DROIDHUB_VIDEO_TEST_RECONNECT"] == "1" {
                let previous = model.selectedDevice?.transportID
                let interrupted = Task { try await library.downloadVideo(large, to: destination) { _ in } }
                defer { interrupted.cancel() }
                try await waitForPartialDownload(in: folder, total: large.bytes)
                _ = try await ProcessRunner.run(adb, ["-s", serial, "reconnect"])
                do {
                    try await interrupted.value
                    XCTFail("\(label): disconnected video unexpectedly finished")
                } catch {
                    XCTAssertFalse(error is CancellationError)
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), label)
                XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasSuffix(".part") })
                if label == "Wi-Fi" {
                    _ = try await ProcessRunner.run(adb, ["connect", serial])
                }
                for _ in 0..<30 {
                    await model.refreshDevices()
                    if model.devices.contains(where: { $0.serial == serial && $0.isOnline && $0.transportID != previous }) { break }
                    try await Task.sleep(for: .milliseconds(200))
                }
                XCTAssertTrue(model.devices.contains { $0.serial == serial && $0.isOnline && $0.transportID != previous }, label)
                print("Verified \(label) mid-transfer disconnect, staging cleanup and reconnect")
            }
            await model.shutdown()
            print("Verified \(label) video filters, three albums, two dates, bounded covers, seek, original bytes, unsupported format, and mid-transfer cancellation")
        }
    }

    private func waitForPartialDownload(in folder: URL, total: Int64) async throws {
        try await wait {
            let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
            return files?.contains { file in
                guard file.pathExtension == "part", let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
                return size > 0 && Int64(size) < total
            } == true
        }
    }

    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw HubError.message("Video fixture did not become ready.")
    }
}
