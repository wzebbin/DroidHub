import CoreGraphics
import Foundation
import ImageIO

enum JPEGEmbeddedThumbnail {
    static let prefixBytes = 128 * 1024
    private static let frameMarkers: Set<UInt8> = [0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf]

    static func decode(prefix: Data, pixels: Int) -> DecodedPhotoImage? {
        let bytes = Array(prefix.prefix(prefixBytes))
        guard bytes.starts(with: [0xff, 0xd8]) else { return nil }
        var cursor = 2
        var size: CGSize?
        var embedded: EXIFThumbnail?
        while cursor < bytes.count, bytes[cursor] == 0xff {
            while cursor < bytes.count, bytes[cursor] == 0xff { cursor += 1 }
            guard cursor < bytes.count else { break }
            let marker = bytes[cursor]
            cursor += 1
            if marker == 0xda || marker == 0xd9 { break }
            guard cursor + 2 <= bytes.count else { break }
            let length = Int(bytes[cursor]) * 256 + Int(bytes[cursor + 1])
            guard length >= 2, length <= bytes.count - cursor else { break }
            let payload = (cursor + 2)..<(cursor + length)
            if marker == 0xe1, embedded == nil {
                embedded = EXIFThumbnail(bytes[payload])
            } else if frameMarkers.contains(marker), payload.count >= 6 {
                let start = payload.lowerBound
                size = CGSize(width: Int(bytes[start + 3]) * 256 + Int(bytes[start + 4]),
                              height: Int(bytes[start + 1]) * 256 + Int(bytes[start + 2]))
            }
            cursor += length
            if size != nil, embedded != nil { break }
        }
        guard let size, size.width > 0, size.height > 0, let embedded else { return nil }
        let original = orientedSize(size, orientation: embedded.originalOrientation)
        guard let source = CGImageSourceCreateWithData(embedded.jpeg as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              max(width, height) >= min(pixels, Int(max(original.width, original.height))) else { return nil }
        let thumbnail = orientedSize(CGSize(width: width, height: height), orientation: embedded.orientation)
        let aspectDifference = (thumbnail.width / thumbnail.height) / (original.width / original.height)
        guard (0.88...1.14).contains(aspectDifference),
              let pixels = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }
        guard let image = orient(pixels, as: embedded.orientation) else { return nil }
        return DecodedPhotoImage(image: image, originalSize: original)
    }

    private static func orient(_ image: CGImage, as orientation: Int) -> CGImage? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let transform: CGAffineTransform
        switch orientation {
        case 2: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0)
        case 3: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case 4: transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        case 5: transform = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: height, ty: width)
        case 6: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        case 7: transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        default: return image
        }
        let size = orientedSize(CGSize(width: width, height: height), orientation: orientation)
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func orientedSize(_ size: CGSize, orientation: Int) -> CGSize {
        (5...8).contains(orientation) ? CGSize(width: size.height, height: size.width) : size
    }
}

private struct EXIFThumbnail {
    let jpeg: Data
    let originalOrientation: Int
    let orientation: Int

    init?(_ payload: ArraySlice<UInt8>) {
        guard payload.starts(with: [0x45, 0x78, 0x69, 0x66, 0, 0]) else { return nil }
        let tiff = Array(payload.dropFirst(6))
        guard tiff.count >= 8 else { return nil }
        let littleEndian = tiff.starts(with: [0x49, 0x49])
        guard littleEndian || tiff.starts(with: [0x4d, 0x4d]) else { return nil }
        func read(_ offset: Int, bytes: Int) -> Int? {
            guard offset >= 0, offset <= tiff.count - bytes else { return nil }
            var value = 0
            for index in 0..<bytes {
                let byte = tiff[offset + (littleEndian ? bytes - index - 1 : index)]
                value = (value << 8) | Int(byte)
            }
            return value
        }
        func directory(_ offset: Int) -> (tags: [Int: Int], next: Int)? {
            guard offset >= 8, let count = read(offset, bytes: 2) else { return nil }
            let nextOffset = offset + 2 + count * 12
            guard let next = read(nextOffset, bytes: 4) else { return nil }
            var tags: [Int: Int] = [:]
            for entry in stride(from: offset + 2, to: nextOffset, by: 12) {
                guard let tag = read(entry, bytes: 2), [0x0112, 0x0103, 0x0201, 0x0202].contains(tag),
                      read(entry + 4, bytes: 4) == 1 else { continue }
                let short = tag == 0x0112 || tag == 0x0103
                guard read(entry + 2, bytes: 2) == (short ? 3 : 4) else { return nil }
                tags[tag] = read(entry + 8, bytes: short ? 2 : 4)
            }
            return (tags, next)
        }
        guard read(2, bytes: 2) == 42, let firstOffset = read(4, bytes: 4),
              let first = directory(firstOffset), first.next != firstOffset,
              let thumbnail = directory(first.next), thumbnail.tags[0x0103] ?? 6 == 6,
              let start = thumbnail.tags[0x0201], start >= 8,
              let length = thumbnail.tags[0x0202], length >= 4, start <= tiff.count - length else { return nil }
        let image = tiff[start..<(start + length)]
        guard image.starts(with: [0xff, 0xd8]), image.suffix(2).elementsEqual([0xff, 0xd9]) else { return nil }
        let primary = first.tags[0x0112] ?? 1
        let orientation = thumbnail.tags[0x0112] ?? primary
        guard (1...8).contains(primary), (1...8).contains(orientation) else { return nil }
        self.originalOrientation = primary
        self.orientation = orientation
        self.jpeg = Data(image)
    }
}
