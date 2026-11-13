import Foundation

public enum PhotoExport {
    public static func filename(for item: MediaItem) -> String {
        LocalFileDestination.safeName(item.name, fallback: "photo.jpg")
    }

    public static func destinations(for items: [MediaItem], directory: URL) -> [URL] {
        var reserved = Set<String>()
        return items.map { LocalFileDestination.uniqueURL(named: filename(for: $0), in: directory, reserving: &reserved) }
    }
}
