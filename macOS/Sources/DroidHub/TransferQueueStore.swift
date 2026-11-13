import Foundation
import DroidHubCore

struct TransferQueueStore: Sendable {
    private static let writer = DispatchQueue(label: "io.droidhub.transfer-queue", qos: .utility)
    private struct Snapshot: Codable {
        let version: Int
        let items: [QueuedTransfer]
    }

    static let applicationURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.droidhub.mac", isDirectory: true)
        .appendingPathComponent("transfer-queue.json")

    let url: URL

    func load() throws -> [QueuedTransfer] {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard snapshot.version == 1, Set(snapshot.items.map(\.id)).count == snapshot.items.count else {
            throw HubError.message(L10n.text("传输队列文件格式无效。"))
        }
        return snapshot.items
    }

    func saveInBackground(_ items: [QueuedTransfer]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.writer.async {
                continuation.resume(with: Result { try save(items) })
            }
        }
    }

    func save(_ items: [QueuedTransfer]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(Snapshot(version: 1, items: items)).write(to: url, options: .atomic)
    }
}
