import OSLog

enum GalleryMetrics {
    private static let logger = Logger(subsystem: "io.droidhub.mac", category: "Gallery")

    static func record(_ event: String, since start: ContinuousClock.Instant, count: Int? = nil, wireless: Bool) {
        let elapsed = start.duration(to: .now).components
        let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
        let transport = wireless ? "Wi-Fi" : "USB"
        let detail = count.map { " count=\($0)" } ?? ""
        logger.info("\(event, privacy: .public) \(milliseconds, privacy: .public) ms \(transport, privacy: .public)\(detail, privacy: .public)")
    }
}
