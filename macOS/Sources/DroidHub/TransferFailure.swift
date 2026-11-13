import Foundation
import Darwin

enum TransferFailure {
    static func requiresUserAction(_ message: String) -> Bool {
        ["传输队列", "存储空间不足", "校验失败", "已变化", "发生变化", "源项目已移动", "已移动、删除", "没有权限", "同名"].contains {
            message.contains($0)
        }
    }

    static func isConnectionLoss(_ error: Error) -> Bool {
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text.contains("device offline") || text.contains("no devices") || text.contains("device disconnected") ||
            (text.contains("device '") && text.contains("not found")) || text.contains("transport error") ||
            text.contains("connection reset") || text.contains("connection refused") ||
            text.contains("no route to host") || text == "error: closed" || text.contains("protocol fault")
    }

    static func message(for error: Error, uploading: Bool) -> String {
        let text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let nsError = error as NSError
        let device = uploading ? "手机" : "Mac"
        if matches(nsError, cocoa: [.fileWriteOutOfSpace], posix: [ENOSPC, EDQUOT]) ||
            lower.contains("no space left") || lower.contains("disk quota") {
            return "\(device)存储空间不足。释放空间后重试。"
        }
        if isConnectionLoss(error) {
            return "手机连接中断。重新连接同一台手机后重试。"
        }
        if lower.contains("unauthorized") { return "手机尚未授权 ADB。请在手机上允许调试连接后重试。" }
        if lower.contains("timed out") || lower.contains("timeout") || text.contains("命令执行超时") {
            return "传输超时。请检查连接后重试。"
        }
        if matches(nsError, cocoa: [.fileWriteFileExists], posix: [EEXIST]) || lower.contains("file exists") {
            return "目标位置已有同名项目。请检查目标位置后重试。"
        }
        if matches(nsError, cocoa: [.fileNoSuchFile, .fileReadNoSuchFile], posix: [ENOENT, ENOTDIR]) ||
            lower.contains("no such file or directory") || lower.contains("cannot stat") {
            return "源文件或目标文件夹已移动、删除或不可访问。请检查路径后重试。"
        }
        if matches(nsError, cocoa: [.fileReadNoPermission, .fileWriteNoPermission], posix: [EACCES, EPERM, EROFS]) ||
            lower.contains("permission denied") || lower.contains("operation not permitted") || lower.contains("read-only file system") {
            return "没有权限读取源文件或写入目标位置。请检查权限或选择其他目录。"
        }
        return text
    }

    private static func matches(_ error: NSError, cocoa: [CocoaError.Code], posix: [Int32]) -> Bool {
        if error.domain == NSCocoaErrorDomain, cocoa.contains(CocoaError.Code(rawValue: error.code)) { return true }
        if error.domain == NSPOSIXErrorDomain, posix.contains(where: { Int($0) == error.code }) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return matches(underlying, cocoa: cocoa, posix: posix)
        }
        return false
    }
}
