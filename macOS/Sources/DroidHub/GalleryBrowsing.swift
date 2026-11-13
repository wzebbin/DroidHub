import Foundation
import DroidHubCore

struct GalleryBrowsing {
    private struct Catalog {
        var revision: UUID?
        var albums = PhotoAlbumCatalog()
        var selectedAlbum: String?
        var pages: [String?: Int] = [:]
        var visible: [MediaItem] = []

        mutating func showPrefix(_ count: Int) {
            visible = Array(albums.photos(in: selectedAlbum).prefix(count))
            pages[selectedAlbum] = visible.count
        }
    }

    static let pageSize = 60
    private var current = Catalog()
    private var previous: Catalog?
    private(set) var showsVideos = false

    var items: [MediaItem] { current.visible }
    var albums: [PhotoAlbum] { current.albums.albums }
    var album: String? { current.selectedAlbum }
    var revision: UUID? { current.revision }
    var all: [MediaItem] { current.albums.all }
    var hasMore: Bool { items.count < current.albums.photos(in: album).count }
    var hasMoreAll: Bool { (current.pages[nil] ?? 0) < current.albums.all.count }

    mutating func selectCachedKind(videos: Bool) -> Bool {
        guard showsVideos != videos, let cached = previous, cached.revision != nil else { return false }
        previous = current
        current = cached
        showsVideos = videos
        return true
    }

    mutating func reload(_ catalog: PhotoAlbumCatalog, videos: Bool, selection: Set<String>, near day: Date?,
                         calendar: Calendar) {
        if showsVideos != videos {
            previous = current
            current = Catalog()
            showsVideos = videos
        }
        let oldAlbum = current.selectedAlbum
        let album = catalog.availableAlbum(oldAlbum)
        let minimum = max(Self.pageSize, current.pages[album] ?? 0)
        let preservePrefix = oldAlbum == album
        let count = PhotoDateGroup.refreshedPrefixCount(in: catalog.photos(in: album), minimum: minimum,
            selection: preservePrefix ? selection : [], near: preservePrefix ? day : nil,
            query: "", calendar: calendar)
        current.albums = catalog
        current.revision = UUID()
        current.pages = current.pages.filter { $0.key == nil || catalog.availableAlbum($0.key) != nil }
        current.selectedAlbum = album
        current.showPrefix(count)
    }

    mutating func selectAlbum(_ id: String?) {
        guard id != album, id == nil || current.albums.availableAlbum(id) != nil else { return }
        current.selectedAlbum = id
        current.showPrefix(max(Self.pageSize, current.pages[id] ?? 0))
    }

    mutating func loadMore() {
        guard hasMore else { return }
        current.showPrefix(items.count + Self.pageSize)
    }

    func visible(in album: String?) -> [MediaItem] {
        album == self.album
            ? items : Array(current.albums.photos(in: album).prefix(current.pages[album] ?? Self.pageSize))
    }

    func searchable(in album: String?) -> [MediaItem] {
        current.albums.photos(in: album)
    }

    static func prepare(_ items: [MediaItem], comparing previous: [MediaItem]? = nil) async throws -> PhotoAlbumCatalog? {
        try Task.checkCancellation()
        if let previous, previous == items { return nil }
        let catalog = PhotoAlbumCatalog(photos: items)
        try Task.checkCancellation()
        return catalog
    }
}

struct GallerySearchKey: Equatable {
    let session: UUID
    let videos: Bool
    let album: String?
    let query: String
    let revision: UUID

    func hasSameScope(as other: Self) -> Bool {
        session == other.session && videos == other.videos && album == other.album && query == other.query
    }
}

struct GallerySearchResults {
    let key: GallerySearchKey
    let matches: [MediaItem]
    var limit = GalleryBrowsing.pageSize

    var visible: [MediaItem] { Array(matches.prefix(limit)) }
    var visibleCount: Int { min(matches.count, limit) }
    var hasMore: Bool { matches.count > limit }

    static func find(_ query: String, in items: [MediaItem]) async throws -> [MediaItem] {
        var matches: [MediaItem] = []
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            if item.name.localizedCaseInsensitiveContains(query) { matches.append(item) }
        }
        try Task.checkCancellation()
        return matches
    }
}
