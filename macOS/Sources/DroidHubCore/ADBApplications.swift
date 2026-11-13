import Foundation

public struct AndroidApplicationDetails: Codable, Equatable, Sendable {
    public let installedAt: Date?
    public let updatedAt: Date?
    public let versionCode: Int64?
    public let minimumSDK: Int?
    public let targetSDK: Int?
    public let splitCount: Int?

    fileprivate init(fields: ArraySlice<Substring>) {
        let values = Array(fields)
        func date(_ index: Int) -> Date? {
            // Some preinstalled packages report a build placeholder near the Unix epoch.
            guard let milliseconds = Int64(values[index]), milliseconds >= 1_199_145_600_000,
                  milliseconds < 253_402_300_800_000 else { return nil }
            return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        }
        installedAt = date(0)
        updatedAt = date(1)
        versionCode = Int64(values[2]).flatMap { $0 >= 0 ? $0 : nil }
        minimumSDK = Int(values[3]).flatMap { $0 > 0 ? $0 : nil }
        targetSDK = Int(values[4]).flatMap { $0 > 0 ? $0 : nil }
        splitCount = Int(values[5]).flatMap { $0 >= 0 ? $0 : nil }
    }
}

public enum AndroidApplicationSort: String, CaseIterable, Sendable {
    case name, recentInstall, recentUpdate, largestAPK

    public func ordered(_ applications: [AndroidApplication]) -> [AndroidApplication] {
        switch self {
        case .name: return applications
        case .recentInstall: return descending(applications) { $0.details?.installedAt }
        case .recentUpdate: return descending(applications) { $0.details?.updatedAt }
        case .largestAPK: return descending(applications, by: \.apkBytes)
        }
    }

    private func descending<Value: Comparable>(_ applications: [AndroidApplication],
                                               by value: (AndroidApplication) -> Value?) -> [AndroidApplication] {
        applications.sorted {
            switch (value($0), value($1)) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            default: return false // Stable sort preserves name order for ties and unavailable fields.
            }
        }
    }
}

public struct AndroidApplication: Identifiable, Codable, Equatable, Sendable {
    public var id: String { package }
    public let package: String
    public let isSystem: Bool
    public let name: String?
    public let iconPNG: Data?
    public let version: String?
    public let apkBytes: Int64?
    public let launcherComponent: String?
    public let details: AndroidApplicationDetails?
    let metadataStamp: String?
    public var displayName: String { name ?? package }

    init(package: String, isSystem: Bool, name: String? = nil, iconPNG: Data? = nil,
         version: String? = nil, apkBytes: Int64? = nil, launcherComponent: String? = nil,
         metadataStamp: String? = nil, details: AndroidApplicationDetails? = nil) {
        self.package = package
        self.isSystem = isSystem
        self.name = name
        self.iconPNG = iconPNG
        self.version = version
        self.apkBytes = apkBytes
        self.launcherComponent = launcherComponent
        self.metadataStamp = metadataStamp
        self.details = details
    }

    public func matches(_ query: String) -> Bool {
        query.isEmpty || package.localizedCaseInsensitiveContains(query)
            || name?.localizedCaseInsensitiveContains(query) == true
    }
}

public struct AndroidApplicationList: Sendable {
    public let user: Int
    public let applications: [AndroidApplication]

    public static func cachedPreview(user: Int, entries: [String: AndroidApplication]) -> Self {
        Self(user: user, applications: []).replacingApplications(Array(entries.values))
    }

    public func preview(cached: [String: AndroidApplication]) -> Self {
        replacingApplications(applications.map { app in
            guard let saved = cached[app.package] else { return app }
            return AndroidApplication(package: app.package, isSystem: app.isSystem, name: saved.name,
                                      iconPNG: saved.iconPNG, version: saved.version, apkBytes: saved.apkBytes,
                                      details: saved.details)
        })
    }

    fileprivate func replacingApplications(_ applications: [AndroidApplication]) -> Self {
        Self(user: user, applications: applications.sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.package < $1.package : order == .orderedAscending
        })
    }
}

extension ADBClient {
    public func currentApplicationUser(device: AndroidDevice) async throws -> Int {
        let data = try await shell(device: device, script: "am get-current-user")
        try Task.checkCancellation()
        guard let user = Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              user >= 0 else { throw HubError.message("无法识别手机当前用户。") }
        return user
    }

    public func applications(device: AndroidDevice, expectedUser: Int? = nil) async throws -> AndroidApplicationList {
        let output = try await shell(device: device, script: """
            set -e
            user=$(am get-current-user)
            printf '%s\\n' "$user"
            pm list packages --user "$user" -3
            printf '%s\\n' --
            pm list packages --user "$user" -s
            [ "$(am get-current-user)" = "$user" ] || { echo '手机用户已切换，请刷新应用列表。' >&2; exit 1; }
            """)
        try Task.checkCancellation()
        let list = try Self.parseApplications(output)
        guard expectedUser == nil || expectedUser == list.user else {
            throw HubError.message("手机用户已切换，请刷新应用列表。")
        }
        return list
    }

    public func applicationDetails(device: AndroidDevice, list: AndroidApplicationList,
                                   cached: [String: AndroidApplication] = [:],
                                   helper: URL? = Bundle.main.url(forResource: "android-app-metadata", withExtension: "jar")) async throws -> AndroidApplicationList {
        guard !list.applications.isEmpty else { return list }
        guard let helper else { throw HubError.message("应用名称和图标读取工具不可用。") }
        let file = try FileHandle(forReadingFrom: helper)
        defer { try? file.close() }
        let stamps = list.applications.compactMap { cached[$0.package]?.metadataStamp }
            .filter(Self.isMetadataStamp).prefix(1_024).map(Shell.quote).joined(separator: " ")
        let stage = Shell.quote("/data/local/tmp/droidhub-app-metadata-" + UUID().uuidString)
        let output = try await shell(device: device, script: """
            set -e
            [ "$(am get-current-user)" = \(list.user) ] || exit 1
            umask 077
            stage=\(stage)
            mkdir -- "$stage"
            trap 'rm -rf -- "$stage"' EXIT
            trap 'exit 1' HUP INT TERM
            helper="$stage/metadata.jar"
            cat > "$helper"
            chmod 400 "$helper"
            CLASSPATH="$helper" app_process /system/bin --nice-name=droidhub-app-metadata AppMetadata \(list.user) \(stamps)
            """, timeout: 45, inputFile: file)
        try Task.checkCancellation()
        return Self.mergeApplicationDetails(output, into: list, cached: cached)
    }

    public func installApplication(device: AndroidDevice, apk: URL, user: Int) async throws {
        guard user >= 0, apk.isFileURL, apk.pathExtension.lowercased() == "apk",
              try apk.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw HubError.message("请选择可读取的 APK 文件。")
        }
        let activeUser = try await shell(device: device, script: "am get-current-user")
        guard Int(String(decoding: activeUser, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) == user else {
            throw HubError.message("手机用户已切换，请刷新应用列表。")
        }
        try Task.checkCancellation()
        let output = try await ProcessRunner.run(executable, Self.deviceArguments(device) + ["install", "--user", String(user), "-r", apk.path], timeout: 300)
        try Task.checkCancellation()
        try Self.requirePackageSuccess(output)
    }

    public func uninstallApplication(device: AndroidDevice, package: String, user: Int) async throws {
        guard user >= 0, Self.isPackageName(package) else { throw HubError.message("应用包名无效。") }
        let output = try await shell(device: device, script: """
            set -e
            [ "$(am get-current-user)" = \(user) ] || {
                echo '手机用户已切换，请刷新应用列表。' >&2
                exit 1
            }
            packages=$(pm list packages --user \(user) -3)
            printf '%s\\n' "$packages" | grep -Fx -- \(Shell.quote("package:" + package)) >/dev/null || {
                echo '该应用当前无法卸载，请刷新应用列表。' >&2
                exit 1
            }
            if result=$(pm uninstall --user \(user) \(Shell.quote(package)) 2>&1); then
                printf '%s\\n' "$result"
            else
                printf '%s\\n' "$result" >&2
                exit 1
            fi
            """, timeout: 90)
        try Task.checkCancellation()
        try Self.requirePackageSuccess(output)
    }

    public func launchApplication(device: AndroidDevice, application: AndroidApplication, user: Int) async throws {
        guard user >= 0, let component = application.launcherComponent,
              Self.isLaunchComponent(component, package: application.package) else {
            throw HubError.message("该应用没有可用的启动入口。")
        }
        let output = try await shell(device: device, script: """
            set -e
            [ "$(am get-current-user)" = \(user) ] || {
                echo '手机用户已切换，请刷新应用列表。' >&2
                exit 1
            }
            am start -W --user \(user) -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n \(Shell.quote(component))
            """, timeout: 20)
        try Task.checkCancellation()
        let message = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard message.split(whereSeparator: \.isNewline).contains(where: { $0 == "Status: ok" }) else {
            throw HubError.message(message.isEmpty ? "手机未确认应用已打开。" : String(message.suffix(1500)))
        }
    }

    static func parseApplications(_ output: Data) throws -> AndroidApplicationList {
        let lines = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard let first = lines.first, let user = Int(first), user >= 0,
              let separator = lines.firstIndex(of: "--") else {
            throw HubError.message("无法读取手机的应用列表。")
        }
        var packages: [String: Bool] = [:]
        for index in lines.indices.dropFirst() where index != separator {
            let line = lines[index]
            let name = String(line.dropFirst("package:".count))
            guard line.hasPrefix("package:"), isPackageName(name) else {
                throw HubError.message("手机返回的应用列表格式有误。")
            }
            packages[name] = index > separator
        }
        let applications = packages.map { AndroidApplication(package: $0.key, isSystem: $0.value) }
            .sorted { $0.package.localizedStandardCompare($1.package) == .orderedAscending }
        return AndroidApplicationList(user: user, applications: applications)
    }

    static func mergeApplicationDetails(_ output: Data, into list: AndroidApplicationList,
                                        cached: [String: AndroidApplication] = [:]) -> AndroidApplicationList {
        let packages = Dictionary(uniqueKeysWithValues: list.applications.map { ($0.package, $0.isSystem) })
        var details: [String: AndroidApplication] = [:]
        for line in String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard [3, 6, 8, 14].contains(fields.count) else { continue }
            let package = String(fields[0])
            guard let isSystem = packages[package] else { continue }
            var name = metadataText(fields[1])
            var icon: Data?
            if !fields[2].isEmpty, fields[2].utf8.count <= 22_000,
               let bytes = Data(base64Encoded: String(fields[2])),
               bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) {
                icon = bytes
            }
            let version = fields.count >= 6 ? metadataText(fields[3]) : nil
            let size = fields.count >= 6 ? Int64(fields[4]) : nil
            let component = fields.count >= 6 ? String(fields[5]) : ""
            var stamp: String?
            if fields.count >= 8, isMetadataStamp(String(fields[6])) {
                let received = String(fields[6])
                if fields[7] == "hit", let saved = cached[package], saved.metadataStamp == received {
                    name = saved.name
                    icon = saved.iconPNG
                    stamp = received
                } else if fields[7] == "fresh", (fields[2].isEmpty || icon != nil), (fields[1].isEmpty || name != nil) {
                    stamp = received
                }
            }
            details[package] = AndroidApplication(package: package, isSystem: isSystem, name: name == package ? nil : name,
                                                  iconPNG: icon, version: version,
                                                  apkBytes: size.flatMap { $0 > 0 ? $0 : nil },
                                                  launcherComponent: isLaunchComponent(component, package: package) ? component : nil,
                                                  metadataStamp: stamp,
                                                  details: fields.count == 14 ? AndroidApplicationDetails(fields: fields[8...]) : nil)
        }
        return list.replacingApplications(list.applications.map { details[$0.package] ?? $0 })
    }

    private static func isMetadataStamp(_ value: String) -> Bool {
        value.utf8.count == 22 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func metadataText(_ value: Substring) -> String? {
        guard !value.isEmpty, value.utf8.count <= 2_800,
              let bytes = Data(base64Encoded: String(value)),
              let text = String(data: bytes, encoding: .utf8) else { return nil }
        let cleaned = text.components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func isLaunchComponent(_ component: String, package: String) -> Bool {
        let parts = component.split(separator: "/", omittingEmptySubsequences: false)
        guard isPackageName(package), parts.count == 2, parts[0] == package,
              !parts[1].isEmpty, component.utf8.count <= 1024 else { return false }
        return parts[1].unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_" || $0 == "$"
        }
    }

    static func isPackageName(_ name: String) -> Bool {
        !name.isEmpty && name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0)
                || (48...57).contains($0) || $0 == 95 }
        }
    }

    private static func requirePackageSuccess(_ output: Data) throws {
        let message = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard message.split(whereSeparator: \.isNewline).contains(where: {
            $0.trimmingCharacters(in: .whitespaces) == "Success"
        }) else {
            throw HubError.message(message.isEmpty ? "手机未确认应用操作成功。" : String(message.suffix(2000)))
        }
    }
}
