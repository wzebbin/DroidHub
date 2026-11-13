import Foundation

extension AndroidApplication {
    public var exportFilenameStem: String {
        let separators = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        func sanitized(_ value: String, byteLimit: Int) -> String {
            let trimmed = value.components(separatedBy: separators).joined(separator: "_")
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
            var result = ""
            var byteCount = 0
            for scalar in trimmed.unicodeScalars {
                let size = scalar.utf8.count
                guard byteCount + size <= byteLimit else { break }
                result.unicodeScalars.append(scalar)
                byteCount += size
            }
            return result
        }
        let name = sanitized(displayName, byteLimit: 160)
        let version = sanitized(version ?? "", byteLimit: 72)
        let stem = name.isEmpty ? sanitized(package, byteLimit: 160) : name
        if !version.isEmpty { return "\(stem) - \(version)" }
        if let code = details?.versionCode { return "\(stem) - \(code)" }
        return stem
    }
}

public struct AndroidApplicationExport: Sendable, Equatable {
    fileprivate let device: AndroidDevice
    fileprivate let package: String
    fileprivate let user: Int
    let paths: [String]
    fileprivate let stamps: [String]

    public var apkCount: Int { paths.count }
    public var fileExtension: String { apkCount == 1 ? "apk" : "zip" }
}

extension ADBClient {
    public func prepareApplicationExport(device: AndroidDevice, package: String, user: Int) async throws -> AndroidApplicationExport {
        guard user >= 0, Self.isPackageName(package) else { throw HubError.message("应用包名或手机用户无效。") }
        guard try await currentApplicationUser(device: device) == user else {
            throw HubError.message("手机用户已切换，请刷新应用列表。")
        }
        let output = try await shell(device: device, script: "pm path --user \(user) \(Shell.quote(package))")
        let paths = try Self.parseApplicationAPKPaths(output)
        let arguments = paths.map(Shell.quote).joined(separator: " ")
        let metadata = try await shell(device: device, script: "stat -c '%s:%Y:%i' \(arguments)")
        let stamps = String(decoding: metadata, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        guard stamps.count == paths.count, stamps.allSatisfy({ (Self.apkSize($0) ?? 0) > 0 }) else {
            throw HubError.message("无法确认手机上安装包的大小。")
        }
        return AndroidApplicationExport(device: device, package: package, user: user, paths: paths, stamps: stamps)
    }

    public func exportApplication(_ export: AndroidApplicationExport, to destination: URL,
                                  replaceExisting: Bool) async throws {
        guard destination.isFileURL, destination.pathExtension.lowercased() == export.fileExtension else {
            throw HubError.message("请将安装包保存为 .\(export.fileExtension) 文件。")
        }
        let manager = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".droidhub-apk-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        let contents = staging.appendingPathComponent("packages", isDirectory: true)
        let packages = try await pullApplicationPackages(export, into: contents)

        let result: URL
        if export.apkCount == 1 {
            result = packages[0]
        } else {
            result = staging.appendingPathComponent("install-packages.zip")
            _ = try await ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", contents.path, result.path], timeout: 900)
        }
        guard try await prepareApplicationExport(device: export.device, package: export.package, user: export.user) == export else {
            throw HubError.message("导出期间手机上的安装包发生变化，请重新导出。")
        }
        try Task.checkCancellation()
        try commitDownload(result, to: destination, replaceExisting: replaceExisting)
    }

    func pullApplicationPackages(_ export: AndroidApplicationExport, into directory: URL) async throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var packages: [URL] = []
        for (path, stamp) in zip(export.paths, export.stamps) {
            try Task.checkCancellation()
            let name = URL(fileURLWithPath: path).lastPathComponent
            let local = directory.appendingPathComponent(name)
            _ = try await ProcessRunner.run(executable, Self.deviceArguments(export.device) + ["pull", path, local.path],
                                            timeout: 900)
            let values = try local.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, Int64(size) == Self.apkSize(stamp) else {
                throw HubError.message("安装包「\(name)」未下载完整，请重试。")
            }
            packages.append(local)
        }
        return packages
    }

    static func parseApplicationAPKPaths(_ output: Data) throws -> [String] {
        let prefix = "package:"
        var paths: [String] = []
        var names = Set<String>()
        for line in String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let path = String(line.dropFirst(prefix.count))
            let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            guard line.hasPrefix(prefix), path.hasPrefix("/"), path.hasSuffix(".apk"),
                  !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  let name = components.last, !name.contains("\\"), !name.contains(":"),
                  names.insert(String(name).precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw HubError.message("手机返回的安装包清单无效，无法安全导出。")
            }
            paths.append(path)
        }
        guard !paths.isEmpty else {
            throw HubError.message("找不到该应用的安装包，应用可能已卸载，请刷新列表。")
        }
        return paths.sorted()
    }

    private static func apkSize(_ stamp: String) -> Int64? {
        Int64(stamp.split(separator: ":", maxSplits: 1).first ?? "")
    }
}
