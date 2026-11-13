import Foundation

public struct PhotoAlbum: Identifiable, Sendable {
    public let path: String
    public let cover: MediaItem
    public let count: Int

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var displayPath: String { path.hasPrefix("/sdcard/") ? String(path.dropFirst("/sdcard/".count)) : path }
}

public struct PhotoAlbumCatalog: Sendable {
    public let all: [MediaItem]
    public let albums: [PhotoAlbum]
    private let byFolder: [String: [MediaItem]]

    // The scanner already sorts the photos newest-first.
    public init(photos: [MediaItem] = []) {
        all = photos
        byFolder = Dictionary(grouping: photos) { ($0.path as NSString).deletingLastPathComponent }
        albums = byFolder.compactMap { path, items in
            items.first.map { PhotoAlbum(path: path, cover: $0, count: items.count) }
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
    }

    public func photos(in albumID: String?) -> [MediaItem] {
        guard let albumID else { return all }
        return byFolder[albumID] ?? []
    }

    public func availableAlbum(_ albumID: String?) -> String? {
        albumID.flatMap { byFolder[$0] == nil ? nil : $0 }
    }
}
