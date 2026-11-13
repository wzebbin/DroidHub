import Foundation

public enum BatchRenameRule: Equatable, Sendable {
    case affixes(prefix: String, suffix: String)
    case replace(find: String, replacement: String)
    case number(prefix: String)

    public var isReady: Bool {
        switch self {
        case .affixes(let prefix, let suffix): return !prefix.isEmpty || !suffix.isEmpty
        case .replace(let find, _): return !find.isEmpty
        case .number: return true
        }
    }

    fileprivate func stem(_ original: String, index: Int, total: Int) -> String {
        switch self {
        case .affixes(let prefix, let suffix):
            return prefix + original + suffix
        case .replace(let find, let replacement):
            return find.isEmpty ? original : original.replacingOccurrences(of: find, with: replacement, options: .literal)
        case .number(let prefix):
            let number = String(index + 1)
            let width = max(3, String(total).count)
            return prefix + String(repeating: "0", count: width - number.count) + number
        }
    }
}

public struct BatchRenamePlan: Sendable {
    public struct Row: Identifiable, Sendable {
        public var id: String { file.id }
        public let file: DeviceFile
        public let name: String
        public let issue: Issue?
        public var changesName: Bool { !file.name.utf8.elementsEqual(name.utf8) }
    }

    public enum Issue: String, Sendable {
        case invalidName = "新名称无效"
        case duplicateResult = "批次内重名"
        case existingName = "目录中已有同名项目"
        case caseOnly = "名称仅大小写不同"
        case sourceChanged = "原项目已变化，请刷新后重新选择"
    }

    public let rows: [Row]
    public var changes: [Row] { rows.filter(\.changesName) }
    public var issues: [Row] { rows.filter { $0.issue != nil } }
    public var canApply: Bool { !changes.isEmpty && issues.isEmpty }

    public init(selection: [DeviceFile], directory: [DeviceFile], rule: BatchRenameRule) {
        let liveFiles = Set(directory)
        let occupied = Set(directory.map { RemoteEntryName.collisionKey($0.name) })
        let names = selection.enumerated().map { index, file in
            let parts = RemoteEntryName.editableParts(of: file)
            let stem = rule.stem(parts.stem, index: index, total: selection.count)
            return (file, stem, stem + parts.suffix)
        }
        let counts = Dictionary(names.map { (RemoteEntryName.collisionKey($0.2), 1) }, uniquingKeysWith: +)
        rows = names.map { file, stem, name in
            let key = RemoteEntryName.collisionKey(name)
            let changed = !file.name.utf8.elementsEqual(name.utf8)
            let issue: Issue?
            if !liveFiles.contains(file) {
                issue = .sourceChanged
            } else if changed && ((try? RemoteEntryName.validate(stem)) == nil || (try? RemoteEntryName.validate(name)) == nil) {
                issue = .invalidName
            } else if changed && counts[key, default: 0] > 1 {
                issue = .duplicateResult
            } else if changed && key == RemoteEntryName.collisionKey(file.name) {
                issue = .caseOnly
            } else if changed && occupied.contains(key) {
                issue = .existingName
            } else {
                issue = nil
            }
            return Row(file: file, name: name, issue: issue)
        }
    }
}
