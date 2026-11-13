import XCTest
@testable import DroidHubCore

final class PhotoTests: XCTestCase {
    func testExportRejectsAnExistingDirectoryBeforeDownloading() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: destination) }
        let original = destination.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: original)
        let library = ADBPhotoLibrary(adb: ADBClient(executable: "/usr/bin/false"), serial: "test")
        let item = MediaItem(path: "/sdcard/Movies/test.mp4", bytes: 100, modifiedAt: 1)
        do {
            try await library.export(item, destination: destination, replaceExisting: true)
            XCTFail("Expected directory protection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("同名文件夹"))
        }
        XCTAssertEqual(try Data(contentsOf: original), Data("keep".utf8))
    }

    func testBatchNamesKeepExistingAndSelectedDuplicates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("existing".utf8).write(to: root.appendingPathComponent("photo.jpg"))
        let items = ["/DCIM/photo.jpg", "/Pictures/photo.jpg", "/Pictures/a:b.png"].map {
            MediaItem(path: $0, bytes: 12, modifiedAt: 1)
        }
        let paths = PhotoExport.destinations(for: items, directory: root)
        XCTAssertEqual(paths.map(\.lastPathComponent), ["photo (2).jpg", "photo (3).jpg", "a_b.png"])
        XCTAssertTrue(paths.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path })
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("photo.jpg")), "existing")
    }

    func testPhotoScanSortsAndKeepsSpecialPaths() throws {
        let first = "/sdcard/DCIM/相机 '\n一.JPG"
        let second = "/sdcard/Pictures/另一个.png"
        let output = ["123.3", "10", first, "123.2", "21", second, "123.3", "10", first, ""].joined(separator: "\0")
        let photos = try ADBPhotoLibrary.parse(Data(output.utf8))
        XCTAssertEqual(photos.map(\.path), [first, second])
        XCTAssertEqual(photos.map(\.bytes), [10, 21])
        XCTAssertEqual(photos.first?.name, "相机 '\n一.JPG")
        XCTAssertThrowsError(try ADBPhotoLibrary.parse(Data(output.dropLast().utf8)))
    }

    func testDateGroupsKeepPaginationSearchAndMidnightOrder() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let formatter = ISO8601DateFormatter()
        let midnight = try XCTUnwrap(formatter.date(from: "2031-04-02T00:00:00+08:00")).timeIntervalSince1970
        let sameDay = (1...61).reversed().map {
            MediaItem(path: "/\($0).png", bytes: 1, modifiedAt: midnight + Double($0))
        }
        let prior = MediaItem(path: "/prior.png", bytes: 1, modifiedAt: midnight - 1)
        let firstPage = PhotoDateGroup.groups(in: Array(sameDay.prefix(60)), calendar: calendar)
        XCTAssertEqual(firstPage.map { $0.items.count }, [60])
        let all = PhotoDateGroup.groups(in: sameDay + [prior], calendar: calendar)
        XCTAssertEqual(all.map { $0.items.count }, [61, 1])
        XCTAssertEqual(firstPage.first?.id, all.first?.id)
        XCTAssertEqual(all.flatMap(\.items), sameDay + [prior])
        let search = PhotoDateGroup.groups(in: [sameDay[0], prior], calendar: calendar)
        XCTAssertEqual(search.map { $0.items.first?.id }, [sameDay[0].id, prior.id])
    }

    func testRefreshKeepsShiftedSelectionsAndTheNearestMatchingDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let photos = [
            MediaItem(path: "/new.png", bytes: 1, modifiedAt: 300_000),
            MediaItem(path: "/unmatched.jpg", bytes: 1, modifiedAt: 250_000),
            MediaItem(path: "/match-anchor.png", bytes: 1, modifiedAt: 150_000),
            MediaItem(path: "/keep-selected.png", bytes: 1, modifiedAt: 1)
        ]
        let missingDay = calendar.startOfDay(for: Date(timeIntervalSince1970: 220_000))
        let prefix = PhotoDateGroup.refreshedPrefixCount(in: photos, minimum: 1, selection: [],
                                                        near: missingDay, query: "match-anchor", calendar: calendar)
        XCTAssertEqual(prefix, 3)
        let retained = PhotoDateGroup.refreshedPrefixCount(in: photos, minimum: 1, selection: [photos[3].id, "/deleted.png"],
                                                          near: missingDay, query: "match-anchor", calendar: calendar)
        XCTAssertEqual(retained, 4)
    }

    func testDateGroupsOnPhoneWhenExplicitlyConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let serial = environment["DROIDHUB_TEST_SERIAL"],
              let directory = environment["DROIDHUB_PHOTO_DATE_TEST_DIRECTORY"],
              let source = environment["DROIDHUB_PHOTO_TEST_FILE"],
              let adb = environment["DROIDHUB_PHOTO_TEST_ADB"] else { throw XCTSkip("No date grouping fixture") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let transports = [serial] + [environment["DROIDHUB_PHOTO_SECOND_SERIAL"]].compactMap { $0 }
        let fixture = try Data(contentsOf: URL(fileURLWithPath: source))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        for transport in transports {
            let library = ADBPhotoLibrary(adb: ADBClient(executable: adb), serial: transport)
            let items = try await library.scan(roots: [directory])
            let first = PhotoDateGroup.groups(in: Array(items.prefix(60)), calendar: calendar)
            XCTAssertEqual(first.map { $0.items.count }, [60])
            let groups = PhotoDateGroup.groups(in: items, calendar: calendar)
            XCTAssertEqual(groups.map { $0.items.count }, [62, 1, 1])
            XCTAssertEqual(groups.first?.id, first.first?.id)
            let midnight = try XCTUnwrap(groups.first?.items.last)
            let before = try XCTUnwrap(groups.dropFirst().first?.items.first)
            XCTAssertEqual(midnight.modifiedAt - before.modifiedAt, 1)
            let searched = items.filter { $0.name.contains("boundary") }
            XCTAssertEqual(PhotoDateGroup.groups(in: searched, calendar: calendar).count, 2)
            for photo in searched {
                let output = destination.appendingPathComponent(photo.name)
                try await library.export(photo, destination: output, replaceExisting: true)
                XCTAssertEqual(try Data(contentsOf: output), fixture)
            }
        }
    }

    func testRealADBPhotoWhenExplicitlyConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let serial = environment["DROIDHUB_TEST_SERIAL"],
              let fixtureDirectory = environment["DROIDHUB_PHOTO_TEST_DIRECTORY"],
              let fixture = environment["DROIDHUB_PHOTO_TEST_FILE"],
              let adb = environment["DROIDHUB_PHOTO_TEST_ADB"] ?? ADBClient.discover("adb") else {
            throw XCTSkip("No explicit ADB photo fixture")
        }
        let client = ADBClient(executable: adb)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let namespace = try await client.hardwareSerial(for: serial)
        let library = ADBPhotoLibrary(adb: client, serial: serial, thumbnailCacheDevice: namespace)
        let photos = try await library.scan(roots: [fixtureDirectory])
        XCTAssertEqual(photos.count, 1)
        let item = try XCTUnwrap(photos.first)
        let diskPath = root.appendingPathComponent("thumbnail-cache", isDirectory: true)
        let pipeline = PhotoImagePipeline(diskCache: PhotoThumbnailDiskCache(directory: diskPath))
        let thumbnail = try await pipeline.image(client: library, item: item, kind: .thumbnail, pixels: 128)
        let preview = try await pipeline.image(client: library, item: item, kind: .preview)
        let pixels = try XCTUnwrap(thumbnail.image)
        XCTAssertLessThanOrEqual(max(pixels.width, pixels.height), 128)
        XCTAssertGreaterThan(preview.cost, thumbnail.cost)
        XCTAssertGreaterThan(preview.originalSize.width, 0)

        if let namespace {
            let reopenedSerial = environment["DROIDHUB_PHOTO_SECOND_SERIAL"] ?? serial
            let reopenedIdentity = try await client.hardwareSerial(for: reopenedSerial)
            XCTAssertEqual(namespace, try XCTUnwrap(reopenedIdentity))
            let reopenedLibrary = ADBPhotoLibrary(adb: client, serial: reopenedSerial, thumbnailCacheDevice: reopenedIdentity)
            let reopenedItems = try await reopenedLibrary.scan(roots: [fixtureDirectory])
            XCTAssertEqual(reopenedItems, photos)
            let reopened = PhotoImagePipeline(diskCache: PhotoThumbnailDiskCache(directory: diskPath)) { _, _, _, _ in
                throw HubError.message("Disk thumbnail was not reused")
            }
            let reused = try await reopened.image(client: reopenedLibrary, item: item, kind: .thumbnail, pixels: 128)
            XCTAssertEqual(reused.originalSize, thumbnail.originalSize)
            XCTAssertEqual(reused.image?.width, pixels.width)
        }
        let output = root.appendingPathComponent("output.png")
        try await library.export(item, destination: output, replaceExisting: false)
        XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: URL(fileURLWithPath: fixture)))

        let wrongSize = MediaItem(path: item.path, bytes: item.bytes + 1, modifiedAt: item.modifiedAt)
        do {
            try await library.export(wrongSize, destination: output, replaceExisting: true)
            XCTFail("Expected a size mismatch")
        } catch {
            XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: URL(fileURLWithPath: fixture)))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0 != "thumbnail-cache" }, ["output.png"])
    }
}
