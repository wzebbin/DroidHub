import SwiftUI
import DroidHubCore

struct PhotoExportProgress {
    let completed: Int
    let total: Int
}

enum PhotoExportResult {
    case saved(count: Int, videos: Bool)
    case interrupted(saved: Int, total: Int, videos: Bool, cancelled: Bool)

    func message(_ l10n: L10n) -> String {
        switch self {
        case let .saved(count, videos):
            return l10n.text("已导出 {1} {2}{3}", count, l10n.text(videos ? "个" : "张"), l10n.text(videos ? "视频" : "照片"))
        case let .interrupted(saved, total, videos, cancelled):
            return l10n.text("{1}，已保存 {2}/{3} {4}{5}", l10n.text(cancelled ? "已取消" : "导出未完成"),
                             saved, total, l10n.text(videos ? "个" : "张"), l10n.text(videos ? "视频" : "照片"))
        }
    }
}

/// Used inside the system save/folder panel so both export entry points share one UI.
struct PhotoExportSummary: View {
    let count: Int
    let bytes: Int64
    let videos: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: videos ? "film" : "photo.on.rectangle").font(.system(size: 23, weight: .light)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text("导出 {1} {2} · {3}", count, videos ? L10n.text("个原始视频") : L10n.text("张原图"), ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))
                    .font(.system(size: 12, weight: .medium))
                Text(count == 1 ? L10n.text("保留原始文件。") : L10n.text("保留原始文件，同名文件自动编号。"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 12).padding(.horizontal, 5).frame(width: 420, alignment: .leading)
    }
}
