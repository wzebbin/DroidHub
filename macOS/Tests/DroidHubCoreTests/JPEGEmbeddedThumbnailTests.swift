import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import DroidHubCore

final class JPEGEmbeddedThumbnailTests: XCTestCase {
    func testEmbeddedThumbnailMatchesOriginalOrientation() throws {
        let original = try jpeg(width: 800, height: 600)
        let thumbnail = try jpeg(width: 400, height: 300)
        for orientation in 1...8 {
            let jpeg = withEXIF(original, thumbnail: thumbnail, orientation: orientation, littleEndian: orientation % 2 == 0)
            let embedded = try XCTUnwrap(JPEGEmbeddedThumbnail.decode(prefix: jpeg, pixels: 320), "EXIF orientation \(orientation), thumbnail tail \(Array(thumbnail.suffix(4)))")
            let full = try PhotoImagePipeline.decode(CGImageSourceCreateWithData(jpeg as CFData, nil), pixels: 320)
            XCTAssertEqual(embedded.originalSize, full.originalSize)
            let actual = try XCTUnwrap(embedded.image)
            let expected = try XCTUnwrap(full.image)
            XCTAssertEqual(actual.width, expected.width)
            XCTAssertEqual(actual.height, expected.height)
            let actualPixels = try quadrants(actual)
            let expectedPixels = try quadrants(expected)
            for (actual, expected) in zip(actualPixels, expectedPixels) {
                XCTAssertLessThan(abs(Int(actual) - Int(expected)), 12, "EXIF orientation \(orientation)")
            }
        }
    }

    func testMissingSmallAndCorruptEmbeddedImagesFallBack() throws {
        let original = try jpeg(width: 800, height: 600)
        let small = try jpeg(width: 160, height: 120)
        let full = try jpeg(width: 400, height: 300)
        XCTAssertNil(JPEGEmbeddedThumbnail.decode(prefix: original, pixels: 320))
        XCTAssertNil(JPEGEmbeddedThumbnail.decode(prefix: withEXIF(original, thumbnail: small), pixels: 320))
        XCTAssertNil(JPEGEmbeddedThumbnail.decode(prefix: withEXIF(original, thumbnail: full, offset: UInt32.max), pixels: 320))
        XCTAssertNil(JPEGEmbeddedThumbnail.decode(prefix: withEXIF(original, thumbnail: full).prefix(80), pixels: 320))
    }

    func testOverlappingFallbackAndPreviewPullOriginalOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.jpg")
        let image = try jpeg(width: 800, height: 600)
        try image.write(to: source)
        let wrapper = directory.appendingPathComponent("adb")
        let ready = directory.appendingPathComponent("ready")
        let release = directory.appendingPathComponent("release")
        let calls = directory.appendingPathComponent("calls")
        let script = """
        #!/bin/sh
        set -e
        [ "$3" = pull ]
        printf 'pull\\n' >> \(Shell.quote(calls.path))
        touch \(Shell.quote(ready.path))
        for i in $(seq 1 500); do
          if [ -f \(Shell.quote(release.path)) ]; then break; fi
          sleep 0.01
        done
        cp \(Shell.quote(source.path)) "$5"
        """
        try Data(script.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let client = ADBPhotoLibrary(adb: ADBClient(executable: wrapper.path), serial: "test")
        let item = MediaItem(path: "/sdcard/DCIM/sample.jpg", bytes: Int64(image.count), modifiedAt: 1)
        let pipeline = PhotoImagePipeline()
        let thumbnail = Task { try await pipeline.image(client: client, item: item, kind: .thumbnail) }
        defer { thumbnail.cancel() }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: ready.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        let preview = Task { try await pipeline.image(client: client, item: item, kind: .preview) }
        defer { preview.cancel() }
        for _ in 0..<100 {
            if await pipeline.pendingConsumerCount == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))
        try Data().write(to: release)
        let smallImage = try await thumbnail.value
        let fullImage = try await preview.value
        XCTAssertEqual(smallImage.image?.width, 320)
        XCTAssertEqual(fullImage.image?.width, 800)
        XCTAssertEqual(try String(contentsOf: calls, encoding: .utf8), "pull\n")
    }

    private func jpeg(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let colors: [[CGFloat]] = [[1, 0, 0, 1], [0, 1, 0, 1], [0, 0, 1, 1], [1, 1, 0, 1]]
        for (index, color) in colors.enumerated() {
            context.setFillColor(try XCTUnwrap(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: color)))
            context.fill(CGRect(x: (index % 2) * width / 2, y: (index / 2) * height / 2, width: width / 2, height: height / 2))
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func quadrants(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                             bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 2))
        let data = try XCTUnwrap(context.data)
        return (0..<16).filter { $0 % 4 != 3 }.map { data.load(fromByteOffset: $0, as: UInt8.self) }
    }

    private func withEXIF(_ original: Data, thumbnail: Data, orientation: Int = 1,
                          littleEndian: Bool = true, offset: UInt32 = 68) -> Data {
        var tiff = Data(littleEndian ? [0x49, 0x49] : [0x4d, 0x4d])
        func append(_ number: UInt32, bytes: Int) {
            for index in 0..<bytes {
                let shift = (littleEndian ? index : bytes - 1 - index) * 8
                tiff.append(UInt8(truncatingIfNeeded: number >> shift))
            }
        }
        func tag(_ id: UInt32, short: Bool, value: UInt32) {
            append(id, bytes: 2)
            append(short ? 3 : 4, bytes: 2)
            append(1, bytes: 4)
            append(value, bytes: short ? 2 : 4)
            if short { append(0, bytes: 2) }
        }
        append(42, bytes: 2)
        append(8, bytes: 4)
        append(1, bytes: 2)
        tag(274, short: true, value: UInt32(orientation))
        append(26, bytes: 4)
        append(3, bytes: 2)
        tag(259, short: true, value: 6)
        tag(513, short: false, value: offset)
        tag(514, short: false, value: UInt32(thumbnail.count))
        append(0, bytes: 4)
        let length = tiff.count + thumbnail.count + 8
        return Data(original.prefix(2)) + Data([0xff, 0xe1, UInt8(length / 256), UInt8(length % 256), 69, 120, 105, 102, 0, 0])
            + tiff + thumbnail + original.dropFirst(2)
    }
}
