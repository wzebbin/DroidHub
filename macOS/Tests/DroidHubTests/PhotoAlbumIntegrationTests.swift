import Foundation
import XCTest
import DroidHubCore
@testable import DroidHub

@MainActor
final class PhotoAlbumIntegrationTests: XCTestCase {
    func testAlbumScopesOnPhoneWhenConfigured() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let usb = env["DROIDHUB_ALBUM_USB"], let wifi = env["DROIDHUB_ALBUM_WIFI"],
              let adb = env["DROIDHUB_ALBUM_ADB"], let dcim = env["DROIDHUB_ALBUM_DCIM"],
              let pictures = env["DROIDHUB_ALBUM_PICTURES"], let fixture = env["DROIDHUB_ALBUM_FIXTURE"] else {
            throw XCTSkip("No explicit album fixture")
        }
        let albumName = "00 DroidHub 相册验收"
        let main = dcim + "/" + albumName
        let other = pictures + "/" + albumName
        let hidden = pictures + "/.album-hidden-for-refresh"
        let bytes = try Data(contentsOf: URL(fileURLWithPath: fixture))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (label, serial) in [("USB", usb), ("Wi-Fi", wifi)] {
            let model = HubModel(transferStorageURL: directory.appendingPathComponent(label).appendingPathComponent("transfers.json"))
            model.adbPath = adb
            await model.refreshDevices()
            model.selectedSerial = serial
            try await wait { model.transfers.connection?.serial == serial }
            XCTAssertEqual(model.selectedDevice?.isWireless, label == "Wi-Fi")
            model.reloadMedia()
            try await wait { !model.galleryLoading && model.photoLibrary != nil }
            let albums = model.photoAlbums.filter { $0.name == albumName }
            XCTAssertEqual(Set(albums.map(\.id)), [main, other])
            XCTAssertEqual(albums.first { $0.id == main }?.count, 64)
            XCTAssertEqual(albums.first { $0.id == other }?.count, 2)
            XCTAssertEqual(albums.first { $0.id == main }?.cover.name, "DH38_main_01.png")
            XCTAssertEqual(Set(albums.map(\.displayPath)).count, 2)
            model.loadMoreMedia()
            let allPage = model.media.map(\.id)

            model.selectPhotoAlbum(main)
            XCTAssertEqual(model.visibleMedia(in: nil).map(\.id), allPage)
            XCTAssertEqual(model.media.count, 60)
            XCTAssertTrue(model.hasMorePhotos)
            let boundary = try await GallerySearchResults.find("boundary", in: model.searchableMedia(in: model.photoAlbumID))
            XCTAssertEqual(boundary.map(\.name), ["DH38_boundary_new.png", "DH38_boundary_old.png"])
            XCTAssertTrue(boundary.allSatisfy { $0.path.hasPrefix(main + "/") })
            model.loadMoreMedia()
            XCTAssertEqual(model.media.count, 64)
            XCTAssertFalse(model.hasMorePhotos)

            model.selectPhotoAlbum(other)
            XCTAssertEqual(model.media.count, 2)
            let otherMatches = try await GallerySearchResults.find("boundary", in: model.searchableMedia(in: model.photoAlbumID))
            XCTAssertTrue(otherMatches.isEmpty)
            model.selectPhotoAlbum(main)
            XCTAssertEqual(model.media.count, 64)
            model.reloadMedia(retaining: Set(boundary.map(\.id)), query: "boundary")
            try await wait { !model.galleryLoading }
            XCTAssertEqual(model.photoAlbumID, main)
            let refreshed = try await GallerySearchResults.find("boundary", in: model.searchableMedia(in: model.photoAlbumID))
            XCTAssertEqual(refreshed, boundary)
            let library = try XCTUnwrap(model.photoLibrary)
            for photo in boundary {
                let output = directory.appendingPathComponent(photo.name)
                try await library.export(photo, destination: output, replaceExisting: true)
                XCTAssertEqual(try Data(contentsOf: output), bytes)
            }

            model.selectPhotoAlbum(nil)
            XCTAssertEqual(model.media.map(\.id), allPage)
            model.selectPhotoAlbum(other)
            _ = try await ProcessRunner.run(adb, ["-s", serial, "shell", "mv -- \(Shell.quote(other)) \(Shell.quote(hidden))"])
            do {
                model.reloadMedia()
                try await wait { !model.galleryLoading }
                XCTAssertNil(model.photoAlbumID)
                XCTAssertFalse(model.photoAlbums.contains { $0.id == other })
                XCTAssertEqual(model.media.count, min(allPage.count, model.photoAlbums.reduce(0) { $0 + $1.count }))
            } catch {
                _ = try? await ProcessRunner.run(adb, ["-s", serial, "shell", "mv -- \(Shell.quote(hidden)) \(Shell.quote(other))"])
                throw error
            }
            _ = try await ProcessRunner.run(adb, ["-s", serial, "shell", "mv -- \(Shell.quote(hidden)) \(Shell.quote(other))"])
            await model.shutdown()
            print("Verified \(label) same-name albums, independent pagination, scoped search and export, and refresh fallback")
        }
    }

    private func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<300 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw HubError.message("Album fixture did not become ready.")
    }
}
