import Foundation
import DroidHubCore

enum RemoteFileRecordWriter {
    private static let queue = DispatchQueue(label: "io.droidhub.remote-file-records", qos: .utility)

    static func save(_ write: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { continuation.resume(with: Result { try write() }) }
        }
    }
}

struct PendingRemoteMove: Codable {
    let device: TransferDeviceID
    let move: RemoteMove
    var batch: BatchRenameProgress?
}

struct BatchRenameProgress: Codable {
    let completed: Int
    let total: Int
}

struct RemoteMoveJournal {
    let url: URL

    func load() throws -> [PendingRemoteMove] {
        do { return try JSONDecoder().decode([PendingRemoteMove].self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    }

    func save(_ moves: [PendingRemoteMove]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(moves).write(to: url, options: .atomic)
    }
}

enum TrashAction: String, Codable {
    case put, restore, restoreToDirectory

    var title: String {
        switch self {
        case .put: return L10n.text("移入回收站")
        case .restore: return L10n.text("恢复到原目录")
        case .restoreToDirectory: return L10n.text("恢复到指定目录")
        }
    }

    var restoreLocation: TrashRestoreLocation? {
        switch self {
        case .put: return nil
        case .restore: return .original
        case .restoreToDirectory: return .chosen
        }
    }

    var completedLabel: String { self == .put ? L10n.text("已移入") : L10n.text("已恢复") }
}

struct TrashEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let device: TransferDeviceID
    let name: String
    let original: String
    let stored: String
    let isDirectory: Bool
    let date: Date
    var partiallyDeleted: Bool?

    static func isStorage(_ path: String) -> Bool {
        path.split(separator: "/").contains { component in
            let prefix = ".droidhub-trash-"
            return component.lowercased().hasPrefix(prefix) && UUID(uuidString: String(component.dropFirst(prefix.count))) != nil
        }
    }
}

struct TrashRestoreRow: Identifiable {
    var id: UUID { entry.id }
    let entry: TrashEntry
    var preview: RestoreMovePreview
}

struct TrashBatch: Codable {
    let action: TrashAction
    let entries: [TrashEntry]
}

struct RemoteMoveBatch: Codable {
    let device: TransferDeviceID
    let destination: String
    let moves: [RemoteMove]
    var trash: TrashBatch?
    var completed = 0
    var checking = false
    var detail: String?
    var failedAt: Int?
    var unresolved: Bool?

    var source: String { moves.first.map { ($0.source as NSString).deletingLastPathComponent } ?? "" }
    var canDiscard: Bool { !checking || (trash == nil && unresolved == true) }
    var isFinished: Bool { completed == moves.count }
    var current: RemoteMove? { moves.dropFirst(completed).first }
}

struct TrashClearRequest {
    let device: TransferDeviceID
    let phoneName: String
    let entries: [TrashEntry]
}

struct TrashDeletionItem: Codable, Identifiable {
    var id: UUID { entry.id }
    let entry: TrashEntry
    let remote: RemoteTrashDeletion
    var state: TrashDeleteState = .pending
}

struct TrashDeletionBatch: Codable {
    let device: TransferDeviceID
    var items: [TrashDeletionItem]
    var isClear: Bool?
    var blockingMessage: String?

    var action: String { isClear == true ? L10n.text("清空回收站") : L10n.text("永久删除") }

    var completed: Int { items.filter { $0.state == .deleted }.count }
    var isFinished: Bool { items.allSatisfy { $0.state == .deleted } }
    var checkIndex: Int? { items.firstIndex { $0.state == .checking || $0.state == .unknown } }
}

struct RemoteMoveSnapshot: Codable {
    var namespace = UUID()
    var batches: [RemoteMoveBatch] = []
    var trash: [TrashEntry] = []
    var deletions: [TrashDeletionBatch]?
}

struct RemoteMoveBatchStore {
    let url: URL

    func load() throws -> [RemoteMoveBatch] { try loadSnapshot().batches }

    func loadSnapshot() throws -> RemoteMoveSnapshot {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let snapshot = try (try? decoder.decode(RemoteMoveSnapshot.self, from: data))
                ?? RemoteMoveSnapshot(batches: decoder.decode([RemoteMoveBatch].self, from: data))
            guard snapshot.batches.allSatisfy({
                (0...$0.moves.count).contains($0.completed) && (!$0.checking || !$0.isFinished)
                && ($0.trash == nil || $0.trash?.entries.count == $0.moves.count)
            }), validDeletions(in: snapshot) else { throw CocoaError(.fileReadCorruptFile) }
            return snapshot
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return RemoteMoveSnapshot() }
    }

    private func validDeletions(in snapshot: RemoteMoveSnapshot) -> Bool {
        let batches = snapshot.deletions ?? []
        let rootName = ".droidhub-trash-" + snapshot.namespace.uuidString.lowercased()
        return Set(batches.map(\.device)).count == batches.count && batches.allSatisfy { batch in
            !batch.items.isEmpty && Set(batch.items.map(\.id)).count == batch.items.count
                && batch.items.allSatisfy { item in
                    let path = item.entry.stored
                    let parent = (path as NSString).deletingLastPathComponent
                    return item.entry.device == batch.device && item.remote.path == path
                        && (parent as NSString).lastPathComponent == rootName
                        && path == (try? ADBClient.entryPath(parent: parent, name: item.id.uuidString))
                }
        }
    }

    func save(_ snapshot: RemoteMoveSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
}
