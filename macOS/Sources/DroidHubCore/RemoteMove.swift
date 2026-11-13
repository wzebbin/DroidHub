import Foundation

public struct RemoteMove: Codable, Sendable {
    public let source: String
    public let destination: String
    public let name: String
    fileprivate let signature: String
    fileprivate let id: UUID

    fileprivate var identity: String { Self.identity(from: signature) }

    fileprivate static func identity(from signature: String) -> String {
        signature.split(separator: ":", maxSplits: 2).prefix(2).joined(separator: ":")
    }

    fileprivate var stage: String { "/data/local/tmp/.droidhub-move-\(id.uuidString)" }
}

public enum RemoteMoveResolution: Equatable, Sendable {
    case moved, unchanged, uncertain
}

public struct RemoteMoveRejection: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

public struct BatchMoveRow: Identifiable, Sendable {
    public var id: String { file.id }
    public let file: DeviceFile
    public let move: RemoteMove?
    public var issue: String?
}

public enum TrashRestoreLocation: Sendable {
    case original, chosen
}

public struct RestoreMovePreview: Sendable {
    public let destination: String
    public let move: RemoteMove?
    public var issues: [String]
}

extension ADBClient {
    public func prepareMove(serial: String, file: DeviceFile, from sourceParent: String,
                            to destinationParent: String) async throws -> RemoteMove {
        let parents = try await canonicalPaths(serial: serial, paths: [sourceParent, destinationParent])
        guard let from = parents[sourceParent], let to = parents[destinationParent] else {
            throw RemoteMoveRejection(message: "无法确认源目录和目标目录。")
        }
        let source = try Self.entryPath(parent: from, name: file.name)
        let destination = try Self.entryPath(parent: to, name: file.name)
        guard source != destination else { throw RemoteMoveRejection(message: "请选择其他目标目录。") }
        if file.isDirectory {
            let resolvedSource = try await canonicalPaths(serial: serial, paths: [source])[source] ?? source
            guard to != resolvedSource, !to.hasPrefix(resolvedSource + "/") else {
                throw RemoteMoveRejection(message: "不能将文件夹移动到自身或子目录。")
            }
        }
        let state = try await readMovePaths(serial: serial, source: source, destination: destination)
        guard state.source != "missing", state.source != "unknown" else {
            throw RemoteMoveRejection(message: "原项目已移动、删除，或没有权限读取。请刷新后重试。")
        }
        guard state.destination != "unknown" else {
            throw RemoteMoveRejection(message: "目标目录不存在或没有权限访问。请重新选择。")
        }
        guard state.destination == "missing" else {
            throw RemoteMoveRejection(message: "目标目录已有同名项目。请换一个目录或先改名。")
        }
        return RemoteMove(source: source, destination: destination, name: file.name, signature: state.source, id: UUID())
    }

    public func previewBatchMove(serial: String, files: [DeviceFile], from sourceParent: String,
                                 to destinationParent: String) async throws -> [BatchMoveRow] {
        let parents = try await canonicalPaths(serial: serial, paths: [sourceParent, destinationParent])
        guard let from = parents[sourceParent], let to = parents[destinationParent] else {
            throw RemoteMoveRejection(message: "无法确认源目录和目标目录。")
        }
        let destinationVolume = try await moveVolume(serial: serial, parent: to)
        let target = to.lowercased()
        let entries = try files.map { file in
            (source: try Self.entryPath(parent: from, name: file.name),
             destination: try Self.entryPath(parent: to, name: file.name))
        }
        let resolved = try await canonicalPaths(serial: serial, paths: zip(files, entries)
            .filter { $0.0.isDirectory }.map { $0.1.source })
        let states = try await inspectBatchMovePaths(serial: serial, paths: entries)
        return zip(zip(files, entries), states).map { entry, state in
            let (file, path) = entry
            let folder = (resolved[path.source] ?? path.source).lowercased()
            let issue: String?
            if from.lowercased() == target {
                issue = "请选择其他目标目录。"
            } else if file.isDirectory && (target == folder || target.hasPrefix(folder + "/")) {
                issue = "不能将文件夹移动到自身或子目录。"
            } else if state.source == "missing" || state.source == "unknown" {
                issue = "原项目已移动、删除或无法读取。"
            } else if state.destination == "unknown" {
                issue = "目标目录不存在或没有权限访问。"
            } else if state.destination != "missing" {
                issue = "目标目录已有同名项目。"
            } else if state.source.split(separator: ":").first != destinationVolume[...] {
                issue = "只能在同一存储卷内移动。"
            } else {
                issue = nil
            }
            let move = issue == nil ? RemoteMove(source: path.source, destination: path.destination,
                                                  name: file.name, signature: state.source, id: UUID()) : nil
            return BatchMoveRow(file: file, move: move, issue: issue)
        }
    }

    public func trashStorage(serial: String, parent: String, name: String) async throws -> String {
        try RemoteEntryName.validate(name)
        let data = try await shell(serial: serial, script: """
            set -e
            parent=\(Shell.quote(parent))
            volume=$(stat -c %d -- "$parent")
            set --
            while [ -d "$parent" ] && [ "$(stat -c %d -- "$parent")" = "$volume" ]; do
              if [ -w "$parent" ] && [ -x "$parent" ]; then set -- "$parent" "$@"; fi
              [ "$parent" != / ] || break
              parent=${parent%/*}
              parent=${parent:-/}
            done
            umask 077
            for candidate; do
              root=${candidate%/}/\(Shell.quote(name))
              # Android can report an ancestor as writable even when mkdir is denied there.
              if mkdir -- "$root" 2>/dev/null || [ -d "$root" ]; then
                if [ ! -L "$root" ] && [ "$(stat -c %d -- "$root")" = "$volume" ]; then
                  printf '%s' "$root"
                  exit 0
                fi
              fi
            done
            echo '这个存储卷没有可写的回收站目录。' >&2
            exit 1
            """)
        let root = String(decoding: data, as: UTF8.self)
        guard root.hasPrefix("/"), root.hasSuffix("/" + name), !root.utf8.contains(0) else {
            throw HubError.message("无法确认手机回收站的位置。")
        }
        return root
    }

    public func previewTrashRestore(serial: String, items: [(name: String, source: String)],
                                    to directory: String) async throws -> [RestoreMovePreview] {
        let volume = try await moveVolume(serial: serial, parent: directory)
        let counts = Dictionary(items.map { (RemoteEntryName.collisionKey($0.name), 1) }, uniquingKeysWith: +)
        let paths = try items.map {
            (source: $0.source, destination: try Self.entryPath(parent: directory, name: $0.name))
        }
        let states = try await inspectBatchMovePaths(serial: serial, paths: paths)
        return zip(zip(items, paths), states).map { itemAndPath, state in
            let (item, path) = itemAndPath
            var issues: [String] = []
            if counts[RemoteEntryName.collisionKey(item.name), default: 0] > 1 {
                issues.append("批次内重名")
            }
            if state.destination == "unknown" {
                issues.append("目标目录不存在或无法访问")
            } else if state.destination != "missing" {
                issues.append("目标目录已有同名项目")
            }
            if state.source == "missing" || state.source == "unknown" {
                issues.append("无法读取回收站项目")
            } else if state.source.split(separator: ":").first != volume[...] {
                issues.append("只能在同一存储卷内恢复")
            }
            let move = issues.isEmpty ? RemoteMove(source: path.source, destination: path.destination,
                                                    name: item.name, signature: state.source, id: UUID()) : nil
            return RestoreMovePreview(destination: path.destination, move: move, issues: issues)
        }
    }

    public func prepareTrashMoves(serial: String, paths: [(name: String, source: String, destination: String)],
                                  restoring: Bool) async throws -> [RemoteMove] {
        let states = try await inspectBatchMovePaths(serial: serial, paths: paths.map { ($0.source, $0.destination) })
        return try zip(paths, states).map { path, state in
            if state.source == "missing" || state.source == "unknown" {
                throw RemoteMoveRejection(message: "无法读取「\(path.name)」。请检查项目是否仍在原位置。")
            }
            try validateMoveDestination(state.destination, name: path.name, restore: restoring ? .original : nil)
            return RemoteMove(source: path.source, destination: path.destination, name: path.name,
                              signature: state.source, id: UUID())
        }
    }

    public func validateBatchMoves(serial: String, moves: [RemoteMove], restore: TrashRestoreLocation? = nil) async throws {
        let states = try await inspectBatchMovePaths(serial: serial, paths: moves.map { ($0.source, $0.destination) })
        let resolved: [String: String]
        if restore != nil {
            let parents = moves.map { ($0.destination as NSString).deletingLastPathComponent }
            resolved = try await canonicalPaths(serial: serial, paths: parents)
        } else {
            resolved = [:]
        }
        var volumes: [String: String] = [:]
        for (move, state) in zip(moves, states) {
            guard state.source == move.signature else {
                throw RemoteMoveRejection(message: L10n.text("「{1}」的源项目已变化。", move.name))
            }
            try validateMoveDestination(state.destination, name: move.name, restore: restore)
            let parent = (move.destination as NSString).deletingLastPathComponent
            if restore != nil && resolved[parent] != parent {
                let directory = restore == .original ? "原目录" : "目标目录"
                throw RemoteMoveRejection(message: L10n.text("「{1}」的{2}指向其他位置，文件保留在回收站。", move.name, L10n.text(directory)))
            }
            let volume: String
            if let known = volumes[parent] {
                volume = known
            } else {
                volume = try await moveVolume(serial: serial, parent: parent)
                volumes[parent] = volume
            }
            guard state.source.split(separator: ":").first == volume[...] else {
                let action = restore == nil ? "移动" : "恢复"
                throw RemoteMoveRejection(message: L10n.text("「{1}」只能在同一存储卷内{2}。", move.name, L10n.text(action)))
            }
        }
    }

    private func validateMoveDestination(_ state: String, name: String, restore: TrashRestoreLocation?) throws {
        guard state != "missing" else { return }
        let directory = restore == .original ? "原目录" : "目标目录"
        let reason = state == "unknown" ? "不存在或无法访问" : "已有同名项目"
        let note = restore == nil ? "。" : "，文件保留在回收站。"
        throw RemoteMoveRejection(message: L10n.text("「{1}」{2}{3}{4}", name, L10n.text(directory), L10n.text(reason), L10n.text(note)))
    }

    private func moveVolume(serial: String, parent: String) async throws -> String {
        let data = try await shell(serial: serial, script: "stat -c %d -- \(Shell.quote(parent))")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func inspectBatchMovePaths(serial: String, paths: [(source: String, destination: String)]) async throws
        -> [(source: String, destination: String)] {
        var states: [String] = []
        var commands = ""
        for path in paths {
            let command = "inspect \(Shell.quote(path.source))\ninspect \(Shell.quote(path.destination))\n"
            if !commands.isEmpty && commands.utf8.count + command.utf8.count > 11_000 {
                states += try await inspectMovePaths(serial: serial, commands: commands)
                commands = ""
            }
            commands += command
        }
        if !commands.isEmpty { states += try await inspectMovePaths(serial: serial, commands: commands) }
        guard states.count == paths.count * 2 else { throw HubError.message("无法核对这批项目的当前路径。") }
        return paths.indices.map { (states[$0 * 2], states[$0 * 2 + 1]) }
    }

    public func applyMove(serial: String, move: RemoteMove) async throws {
        let helper = try await androidMoveHelper(serial: serial)
        let stage = Shell.quote(move.stage)
        let executable = Shell.quote(move.stage + "/move")
        _ = try await shell(serial: serial, script: "umask 077; mkdir -- \(stage)")
        _ = try await ProcessRunner.run(self.executable, ["-s", serial, "push", helper.path, move.stage + "/move"])
        try Task.checkCancellation()
        let result = try await shell(serial: serial, script: """
            set -e
            \(moveLock)
            [ -f \(executable) ]
            move_stage=\(stage)
            trap 'rm -rf -- "$move_stage"' EXIT
            chmod 700 \(executable)
            \(executable) \(Shell.quote(move.source)) \(Shell.quote(move.destination)) \(Shell.quote(move.identity)) 3<&9
            """)
        let code = String(decoding: result, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch code {
        case "moved": return
        case "exists": throw RemoteMoveRejection(message: "目标目录已有同名项目。请换一个目录或先改名。")
        case "cross-volume": throw RemoteMoveRejection(message: "只能在同一存储卷内移动。请选择同一存储卷的目标目录。")
        case "denied": throw RemoteMoveRejection(message: "没有权限移动这个项目。请检查源目录和目标目录。")
        case "source-changed", "path-changed": throw RemoteMoveRejection(message: "源项目或目标目录已变化。请刷新后重试。")
        case "unsupported": throw RemoteMoveRejection(message: "手机或目标文件系统不支持安全移动。请选择其他目录。")
        case "no-space": throw RemoteMoveRejection(message: "手机存储空间不足。释放空间后重试。")
        case "failed": throw RemoteMoveRejection(message: "手机未能移动这个项目。请检查源目录和目标目录。")
        default: throw HubError.message("手机没有返回可确认的移动结果。")
        }
    }

    public func prepareBatchRenames(serial: String, parent: String, plan: BatchRenamePlan) async throws -> [RemoteMove] {
        guard plan.canApply, let directory = try await canonicalPaths(serial: serial, paths: [parent])[parent] else {
            throw RemoteMoveRejection(message: "请先处理预览中的冲突并确认新名称。")
        }
        let paths = try plan.changes.map { row in
            (source: try Self.entryPath(parent: directory, name: row.file.name),
             destination: try Self.entryPath(parent: directory, name: row.name),
             name: row.file.name)
        }
        let states = try await inspectBatchMovePaths(serial: serial, paths: paths.map { ($0.source, $0.destination) })
        return try zip(paths, states).map { path, state in
            guard state.source != "missing", state.source != "unknown" else {
                throw RemoteMoveRejection(message: "「\(path.name)」已移动、删除，或没有权限读取。请刷新后重试。")
            }
            guard state.destination == "missing" else {
                let message = state.destination == "unknown" ? "无法访问目标目录。" : "目录中已有同名项目。"
                throw RemoteMoveRejection(message: "「\(path.name)」无法重命名。\(message)请重新预览。")
            }
            return RemoteMove(source: path.source, destination: path.destination, name: path.name,
                              signature: state.source, id: UUID())
        }
    }

    public func reconcileMove(serial: String, move: RemoteMove) async throws -> RemoteMoveResolution {
        let state = try await readMovePaths(serial: serial, source: move.source, destination: move.destination,
                                            recovering: move)
        // Android shared storage can update a directory's mtime when renaming it.
        let source = RemoteMove.identity(from: state.source)
        let destination = RemoteMove.identity(from: state.destination)
        if state.source == "missing", destination == move.identity { return .moved }
        if source == move.identity, destination != move.identity, state.destination != "unknown" {
            return .unchanged
        }
        return .uncertain
    }

    private func readMovePaths(serial: String, source: String, destination: String,
                               recovering move: RemoteMove? = nil) async throws -> (source: String, destination: String) {
        let lock = move.map { """
            \(moveLock)
            move_stage=\(Shell.quote($0.stage))
            trap 'rm -rf -- "$move_stage"' EXIT
            """ } ?? ""
        let lines = try await inspectMovePaths(serial: serial, lock: lock,
                                               commands: "inspect \(Shell.quote(source))\ninspect \(Shell.quote(destination))")
        guard lines.count == 2 else { throw HubError.message("无法核对移动的源目录和目标目录。") }
        return (lines[0], lines[1])
    }

    private func inspectMovePaths(serial: String, lock: String = "", commands: String) async throws -> [String] {
        let data = try await shell(serial: serial, script: """
            set -e
            \(lock)
            inspect() {
              parent=${1%/*}
              parent=${parent:-/}
              if [ ! -d "$parent" ] || [ ! -r "$parent" ] || [ ! -x "$parent" ]; then
                echo unknown
              elif [ -e "$1" ] || [ -L "$1" ]; then
                stat -c '%d:%i:%s:%y:%f' -- "$1" 2>/dev/null || echo unknown
              else
                echo missing
              fi
            }
            \(commands)
            """)
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }

    var moveLock: String {
        """
        umask 077
        exec 9>>/data/local/tmp/.droidhub-move.lock
        flock 0 <&9
        """
    }

    func androidMoveHelper(serial: String) async throws -> URL {
        let data = try await shell(serial: serial, script: "getprop ro.product.cpu.abilist; getprop ro.product.cpu.abi")
        let supported = Set(["arm64-v8a", "armeabi-v7a", "x86_64", "x86"])
        let abi = String(decoding: data, as: UTF8.self)
            .split { $0 == "," || $0.isWhitespace }.map(String.init).first { supported.contains($0) }
        let configured = ProcessInfo.processInfo.environment["DROIDHUB_ANDROID_MOVE_HELPERS"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let resources = configured ?? Bundle.main.resourceURL?.appendingPathComponent("android-move", isDirectory: true)
        guard let abi, let helper = resources?.appendingPathComponent(abi),
              FileManager.default.isReadableFile(atPath: helper.path) else {
            throw RemoteMoveRejection(message: "找不到适用于这台手机的移动组件。请使用完整的 DroidHub 安装包。")
        }
        return helper
    }
}
