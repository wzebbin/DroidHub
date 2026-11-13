import Foundation

public struct PhotoDateGroup: Identifiable, Sendable {
    public let day: Date
    public private(set) var items: [MediaItem]
    public var id: Date { day }

    // The gallery and its filtered results already share newest-first order.
    public static func groups(in photos: [MediaItem], calendar: Calendar) -> [Self] {
        var groups: [Self] = []
        for photo in photos {
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: photo.modifiedAt))
            if let last = groups.indices.last, groups[last].day == day {
                groups[last].items.append(photo)
            } else {
                groups.append(Self(day: day, items: [photo]))
            }
        }
        return groups
    }

    public static func refreshedPrefixCount(in photos: [MediaItem], minimum: Int, selection: Set<String>,
                                            near day: Date?, query: String, calendar: Calendar) -> Int {
        var count = min(minimum, photos.count)
        guard !selection.isEmpty || day != nil else { return count }
        var closest: (index: Int, distance: TimeInterval)?
        for (index, photo) in photos.enumerated() {
            if selection.contains(photo.id) { count = max(count, index + 1) }
            if let day, closest?.distance != 0, query.isEmpty || photo.name.localizedCaseInsensitiveContains(query) {
                let date = calendar.startOfDay(for: Date(timeIntervalSince1970: photo.modifiedAt))
                let distance = abs(date.timeIntervalSince(day))
                if closest.map({ distance < $0.distance }) ?? true {
                    closest = (index, distance)
                }
            }
        }
        if let closest { count = max(count, closest.index + 1) }
        return count
    }

    public static func nearestDay(to day: Date, in groups: [Self]) -> Date? {
        groups.min { abs($0.day.timeIntervalSince(day)) < abs($1.day.timeIntervalSince(day)) }?.day
    }
}
