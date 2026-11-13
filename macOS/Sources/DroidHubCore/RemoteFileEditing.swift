import Foundation

public enum RemoteEntryName {
    static func collisionKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    public static func validate(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0),
              name.utf8.count <= 255 else {
            throw HubError.message("请输入有效名称。名称不能包含斜杠，长度最多为 255 字节。")
        }
    }

    public static func editableParts(of file: DeviceFile) -> (stem: String, suffix: String) {
        let name = file.name
        guard !file.isDirectory, let dot = name.lastIndex(of: "."), dot != name.startIndex,
              name.index(after: dot) != name.endIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }

    public static func renamed(_ file: DeviceFile, stem: String) throws -> String {
        let original = editableParts(of: file)
        if stem == original.stem { return file.name }
        let suffix = original.suffix
        let base = !suffix.isEmpty && stem.lowercased().hasSuffix(suffix.lowercased())
            ? String(stem.dropLast(suffix.count)) : stem
        try validate(base)
        let name = base + suffix
        try validate(name)
        return name
    }
}

extension ADBClient {
    public func createDirectory(serial: String, parent: String, name: String) async throws {
        let target = Shell.quote(try Self.entryPath(parent: parent, name: name))
        _ = try await shell(serial: serial, script: """
            if mkdir -- \(target); then exit 0; fi
            if [ -e \(target) ] || [ -L \(target) ]; then
              echo '目标目录已有同名项目。请换一个名称。' >&2
            fi
            exit 1
            """)
    }

    public func renameEntry(serial: String, parent: String, file: DeviceFile, stem: String) async throws {
        let name = try RemoteEntryName.renamed(file, stem: stem)
        let source = Shell.quote(try Self.entryPath(parent: parent, name: file.name))
        let target = Shell.quote(try Self.entryPath(parent: parent, name: name))
        guard source != target else { return }
        _ = try await shell(serial: serial, script: """
            set -e
            if [ ! -e \(source) ] && [ ! -L \(source) ]; then
              echo '原项目已移动或删除。请刷新目录后重试。' >&2
              exit 1
            fi
            if [ -e \(target) ] || [ -L \(target) ]; then
              echo '目标目录已有同名项目。请换一个名称。' >&2
              exit 1
            fi
            mv -nT -- \(source) \(target)
            if [ -e \(source) ] || [ -L \(source) ]; then
              echo '目标目录已有同名项目。请换一个名称。' >&2
              exit 1
            fi
            """)
    }

    public func canonicalPaths(serial: String, paths: [String]) async throws -> [String: String] {
        let helper = #"""
        canonical() {
          item=$1
          suffix=
          while :; do
            if resolved=$(realpath -- "$item" 2>/dev/null && printf /); then
              resolved=${resolved%?}
              resolved=${resolved%?}
              printf '%s\0' "${resolved%/}$suffix"
              return
            fi
            [ "$item" != / ] || return 1
            suffix="/${item##*/}$suffix"
            item=${item%/*}
            item=${item:-/}
          done
        }
        """#
        var result: [String: String] = [:]
        var batch: [String] = []
        var script = "set -e\n" + helper + "\n"
        func resolveBatch() async throws {
            guard !batch.isEmpty else { return }
            let data = try await shell(serial: serial, script: script)
            let fields = data.split(separator: 0, omittingEmptySubsequences: false)
            guard fields.count == batch.count + 1, fields.last?.isEmpty == true else {
                throw HubError.message("无法确认手机上的文件路径，请刷新后重试。")
            }
            for (path, field) in zip(batch, fields) {
                let value = String(decoding: field, as: UTF8.self)
                result[path] = value.isEmpty ? "/" : value
            }
        }
        for path in Set(paths) {
            guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw HubError.message("手机目录路径无效。") }
            let command = "canonical \(Shell.quote(path))\n"
            if script.utf8.count + command.utf8.count > 12_000 {
                try await resolveBatch()
                batch.removeAll(keepingCapacity: true)
                script = "set -e\n" + helper + "\n"
            }
            batch.append(path)
            script += command
        }
        try await resolveBatch()
        return result
    }

    public static func entryPath(parent: String, name: String) throws -> String {
        guard parent.hasPrefix("/"), !parent.utf8.contains(0) else { throw HubError.message("手机目录路径无效。") }
        try RemoteEntryName.validate(name)
        return parent + (parent.hasSuffix("/") ? "" : "/") + name
    }
}
