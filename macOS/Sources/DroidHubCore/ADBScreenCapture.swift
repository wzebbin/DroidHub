import Foundation
import ImageIO
import UniformTypeIdentifiers

extension ADBClient {
    public func saveScreenshot(serial: String, in directory: URL) async throws -> URL {
        let data = try await ProcessRunner.run(executable, ["-s", serial, "exec-out", "screencap", "-p"], timeout: 15)
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw HubError.message(L10n.text("手机没有返回完整的 PNG 截图。请确认手机仍在线，再试一次。"))
        }

        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd HHmmss"
        let id = UUID().uuidString
        let destination = directory.appendingPathComponent(L10n.text("手机截图 {1}-{2}.png", date.string(from: .now), id.prefix(8)))
        let staging = directory.appendingPathComponent(".capture-\(id).part")
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        try data.write(to: staging, options: .withoutOverwriting)
        try Task.checkCancellation()
        try manager.moveItem(at: staging, to: destination)
        return destination
    }
}
