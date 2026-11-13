import Foundation

public enum TrashDeleteState: String, Codable, Sendable {
    case pending, checking, deleted, present, partial, unknown
}

public struct RemoteTrashDeletion: Codable, Sendable {
    public let path: String
    fileprivate let parentID: String
    fileprivate let itemID: String
    fileprivate let contents: String
    fileprivate let stageID: UUID

    fileprivate var stage: String { "/data/local/tmp/.droidhub-delete-\(stageID.uuidString)" }
}

extension ADBClient {
    public func prepareTrashDeletion(serial: String, path: String, namespace: UUID, entryID: UUID,
                                     isDirectory: Bool) async throws -> RemoteTrashDeletion {
        let parent = (path as NSString).deletingLastPathComponent
        let expected = ".droidhub-trash-" + namespace.uuidString.lowercased()
        guard (parent as NSString).lastPathComponent == expected,
              path == (try Self.entryPath(parent: parent, name: entryID.uuidString)) else {
            throw HubError.message("无法确认此项目属于当前 Mac 的回收站。")
        }
        let state = try await trashDeletionProbe(serial: serial, path: path, isDirectory: isDirectory)
        guard state.count == 4, state[0] == "present" else {
            throw HubError.message("无法确认手机上的回收站项目。")
        }
        return RemoteTrashDeletion(path: path, parentID: state[1], itemID: state[2], contents: state[3], stageID: UUID())
    }

    public func reconcileTrashDeletion(serial: String, item: RemoteTrashDeletion) async throws -> TrashDeleteState {
        let state = try await trashDeletionProbe(serial: serial, path: item.path, expected: item, cleanup: true)
        guard let code = state.first, let result = TrashDeleteState(rawValue: code),
              result != .pending, result != .checking else { return .unknown }
        return result
    }

    public func applyTrashDeletion(serial: String, item: RemoteTrashDeletion) async throws -> TrashDeleteState {
        let helper = try await androidMoveHelper(serial: serial)
        let stage = Shell.quote(item.stage)
        let tool = Shell.quote(item.stage + "/delete")
        _ = try await shell(serial: serial, script: "umask 077; mkdir -- \(stage)")
        _ = try await ProcessRunner.run(executable, ["-s", serial, "push", helper.path, item.stage + "/delete"])
        try Task.checkCancellation()
        let parent = (item.path as NSString).deletingLastPathComponent
        let name = (item.path as NSString).lastPathComponent
        let state = try await trashDeletionProbe(serial: serial, path: item.path, expected: item, cleanup: true, mutation: """
            chmod 700 \(tool)
            \(tool) --delete \(Shell.quote(parent)) \(Shell.quote(name)) \(Shell.quote(item.parentID)) \(Shell.quote(item.itemID)) 3<&9 || :
            """)
        guard let code = state.first, let result = TrashDeleteState(rawValue: code),
              result != .pending, result != .checking else { return .unknown }
        return result
    }

    private func trashDeletionProbe(serial: String, path: String, isDirectory: Bool = false,
                                    expected: RemoteTrashDeletion? = nil, cleanup: Bool = false,
                                    mutation: String = "") async throws -> [String] {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let stageCleanup = cleanup && expected != nil ? """
            deletion_stage=\(Shell.quote(expected?.stage ?? ""))
            trap 'rm -rf -- "$deletion_stage"' EXIT
            """ : ""
        let data = try await shell(serial: serial, script: """
            set -e
            set -o pipefail
            \(moveLock)
            \(stageCleanup)
            parent=\(Shell.quote(parent))
            name=\(Shell.quote(name))
            parent_id=\(Shell.quote(expected?.parentID ?? ""))
            item_id=\(Shell.quote(expected?.itemID ?? ""))
            original_contents=\(Shell.quote(expected?.contents ?? ""))
            unknown() { printf '%s\\n' unknown; exit 0; }
            cd -P -- "$parent" 2>/dev/null || unknown
            [ "$PWD" = "$parent" ] && [ -r . ] && [ -x . ] || unknown
            current_parent=$(stat -c '%d:%i' -- . 2>/dev/null) || unknown
            [ -z "$parent_id" ] || [ "$parent_id" = "$current_parent" ] || unknown
            probe() {
              if [ ! -e "$name" ] && [ ! -L "$name" ]; then
                # Read the parent successfully before using absence as a deletion result.
                ls -a -- . >/dev/null 2>&1 || unknown
                [ ! -e "$name" ] && [ ! -L "$name" ] || unknown
                printf '%s\\n' deleted
                exit 0
              fi
              current_item=$(stat -c '%d:%i' -- "$name" 2>/dev/null) || unknown
              [ -z "$item_id" ] || [ "$item_id" = "$current_item" ] || unknown
            }
            probe
            \(mutation)
            probe
            contents=file
            if [ -d "$name" ] && [ ! -L "$name" ]; then
              contents=$(LC_ALL=C find "$name" -xdev -print0 | LC_ALL=C sort -z | sha256sum) || unknown
            fi
            if [ -z "$item_id" ]; then
              [ \(isDirectory ? "directory" : "file") = directory ] && [ "$contents" = file ] && unknown
              [ \(isDirectory ? "directory" : "file") = file ] && [ "$contents" != file ] && unknown
              printf '%s\\n' present "$current_parent" "$current_item" "$contents"
            elif [ "$original_contents" = "$contents" ]; then
              printf '%s\\n' present
            else
              printf '%s\\n' partial
            fi
            """, timeout: 120)
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }
}
