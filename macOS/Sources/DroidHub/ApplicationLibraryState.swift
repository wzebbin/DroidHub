import AppKit
import Combine
import Foundation
import DroidHubCore
import UniformTypeIdentifiers

@MainActor
final class ApplicationLibraryState: ObservableObject {
    @Published var applicationListFailure: String?
    @Published var applicationList: AndroidApplicationList?
    @Published var applicationListVerified = false
    @Published var applicationNotice: String?
    @Published var exportedPackageURL: URL?
    @Published var applicationDetailsUnavailable = false
    @Published var loadingApplicationDetails = false
    var detailsWork: Task<Void, Never>?

    func reset() {
        applicationListFailure = nil
        applicationList = nil
        applicationListVerified = false
        applicationNotice = nil
        exportedPackageURL = nil
        applicationDetailsUnavailable = false
        cancelDetails()
    }

    func cancelDetails() {
        detailsWork?.cancel()
        detailsWork = nil
        loadingApplicationDetails = false
    }
}

extension HubModel {
    func loadApplicationsWhenReady() async {
        let session = deviceSession
        await waitForForegroundWork(in: session)
        guard !Task.isCancelled, deviceSession == session, !applications.applicationListVerified else { return }
        refreshApplications()
    }

    func refreshApplications() {
        performApplicationAction(L10n.text("读取应用列表"), session: deviceSession)
    }

    func installApplication(_ apk: URL, session: UUID, user: Int) {
        guard applications.applicationListVerified, applications.applicationList?.user == user else { return }
        performApplicationAction(L10n.text("安装 APK"), session: session) { client, device in
            try await client.installApplication(device: device, apk: apk, user: user)
        }
    }

    func uninstallApplication(_ package: String, session: UUID, user: Int) {
        guard applications.applicationListVerified, applications.applicationList?.user == user,
              applications.applicationList?.applications.contains(where: { $0.package == package && !$0.isSystem }) == true else { return }
        performApplicationAction(L10n.text("卸载应用"), session: session) { client, device in
            try await client.uninstallApplication(device: device, package: package, user: user)
        }
    }

    func launchApplication(_ package: String, session: UUID, user: Int) {
        guard !busy, applications.applicationListVerified, deviceSession == session, let device = selectedDevice, device.isOnline,
              let list = applications.applicationList, list.user == user,
              let app = list.applications.first(where: { $0.package == package && $0.launcherComponent != nil }) else { return }
        let client = adb
        applications.applicationNotice = nil
        applications.exportedPackageURL = nil
        perform(L10n.text("在手机上打开「{1}」", app.displayName), reportsCompletion: false) {
            try await client.launchApplication(device: device, application: app, user: user)
            try Task.checkCancellation()
            guard self.deviceSession == session else { throw CancellationError() }
            self.applications.applicationNotice = L10n.text("已在手机上打开「{1}」", app.displayName)
        }
    }

    func exportApplication(_ package: String, session: UUID, user: Int) {
        guard !busy, deviceSession == session, let device = selectedDevice, device.isOnline,
              applications.applicationListVerified, let list = applications.applicationList, list.user == user,
              list.applications.contains(where: { $0.package == package }) else { return }
        let client = adb
        let previousStatus = status
        perform(L10n.text("正在读取安装包…"), reportsCompletion: false) {
            let export = try await client.prepareApplicationExport(device: device, package: package, user: user)
            await self.applications.detailsWork?.value
            try Task.checkCancellation()
            guard self.deviceSession == session, self.applications.applicationList?.user == user,
                  let app = self.applications.applicationList?.applications.first(where: { $0.package == package }) else {
                throw CancellationError()
            }

            let panel = NSSavePanel()
            panel.title = L10n.text("导出安装包")
            panel.prompt = L10n.text("导出")
            panel.isExtensionHidden = false
            if let type = UTType(filenameExtension: export.fileExtension) {
                panel.allowedContentTypes = [type]
                panel.nameFieldStringValue = app.exportFilenameStem
            } else {
                panel.nameFieldStringValue = "\(app.exportFilenameStem).\(export.fileExtension)"
            }
            panel.message = export.apkCount == 1
                ? L10n.text("将「{1}」的单个 APK 保存到 Mac。", app.displayName)
                : L10n.text("「{1}」有 {2} 个分包，连同基础 APK 共 {3} 个文件，将保存为 ZIP。ZIP 不能作为单个 APK 安装。", app.displayName, export.apkCount - 1, export.apkCount)
            guard panel.runModal() == .OK, let destination = panel.url else {
                if self.deviceSession == session { self.status = previousStatus }
                return
            }
            try Task.checkCancellation()
            guard self.deviceSession == session else { throw CancellationError() }
            self.applications.applicationNotice = nil
            self.applications.exportedPackageURL = nil
            self.status = L10n.text("正在导出安装包…")
            try await client.exportApplication(export, to: destination,
                                               replaceExisting: FileManager.default.fileExists(atPath: destination.path))
            guard self.deviceSession == session else { throw CancellationError() }
            self.status = L10n.text("安装包已导出")
            self.applications.applicationNotice = L10n.text("已导出「{1}」", destination.lastPathComponent)
            self.applications.exportedPackageURL = destination
        }
    }

    func revealExportedApplication(_ destination: URL) {
        guard applications.exportedPackageURL == destination else { return }
        guard FileManager.default.fileExists(atPath: destination.path) else {
            applications.exportedPackageURL = nil
            applications.applicationNotice = nil
            error = L10n.text("导出的安装包已被移动或删除。")
            return
        }
        revealFileInFinder(destination, failureMessage: L10n.text("无法在 Finder 中显示安装包"))
    }

    private func performApplicationAction(_ title: String, session: UUID,
                                          action: ((ADBClient, AndroidDevice) async throws -> Void)? = nil) {
        guard !busy, deviceSession == session, let device = selectedDevice, device.isOnline else { return }
        let client = adb
        applications.applicationNotice = nil
        applications.exportedPackageURL = nil
        applications.applicationDetailsUnavailable = false
        applications.applicationListFailure = nil
        applications.cancelDetails()
        applications.applicationListVerified = false
        perform(title, reportsCompletion: false) {
            var cached: [String: AndroidApplication]?
            var expectedUser: Int?
            if let action {
                do {
                    try await action(client, device)
                } catch {
                    if Task.isCancelled, self.deviceSession == session { self.applications.applicationList = nil }
                    throw error
                }
                try Task.checkCancellation()
                guard self.deviceSession == session else { throw CancellationError() }
                self.applications.applicationList = nil
                self.applications.applicationNotice = title + L10n.text("完成")
            } else if self.applications.applicationList == nil {
                if let fingerprint = await self.hardwareFingerprint(in: session),
                   let user = try? await client.currentApplicationUser(device: device) {
                    expectedUser = user
                    cached = await ApplicationMetadataCache.shared.read(device: fingerprint, user: user)
                    try Task.checkCancellation()
                    guard self.deviceSession == session else { throw CancellationError() }
                    if let cached, !cached.isEmpty {
                        self.applications.applicationList = .cachedPreview(user: user, entries: cached)
                    }
                }
            }
            let list: AndroidApplicationList
            do {
                list = try await client.applications(device: device, expectedUser: expectedUser)
            } catch {
                if expectedUser != nil, self.deviceSession == session {
                    self.applications.applicationList = nil
                }
                try Task.checkCancellation()
                guard self.deviceSession == session else { throw CancellationError() }
                self.applications.applicationListFailure = action == nil ? L10n.diagnostic(error.localizedDescription)
                    : L10n.text("应用操作已完成。{1}", L10n.diagnostic(error.localizedDescription))
                self.status = L10n.text("应用列表读取失败")
                return
            }
            try Task.checkCancellation()
            guard self.deviceSession == session else { throw CancellationError() }
            if let current = self.applications.applicationList, current.user == list.user {
                let visible = Dictionary(uniqueKeysWithValues: current.applications.map { ($0.package, $0) })
                self.applications.applicationList = list.preview(cached: visible)
            } else {
                self.applications.applicationList = list
            }
            self.applications.applicationListVerified = true
            self.status = title + L10n.text("完成")
            self.loadApplicationDetails(list, client: client, device: device, session: session, cached: cached)
        }
    }

    private func loadApplicationDetails(_ list: AndroidApplicationList, client: ADBClient, device: AndroidDevice,
                                        session: UUID, cached: [String: AndroidApplication]?) {
        guard !list.applications.isEmpty else { return }
        applications.loadingApplicationDetails = true
        applications.detailsWork = Task { [weak self] in
            let fingerprint = await self?.hardwareFingerprint(in: session)
            guard !Task.isCancelled, let self, self.deviceSession == session else { return }
            let cache = ApplicationMetadataCache.shared
            let saved: [String: AndroidApplication]
            if let cached {
                saved = cached
            } else if let fingerprint {
                saved = await cache.read(device: fingerprint, user: list.user)
            } else {
                saved = [:]
            }
            guard !Task.isCancelled, self.deviceSession == session else { return }
            if !saved.isEmpty, let current = self.applications.applicationList {
                var preview = saved
                for app in current.applications where app.name != nil || app.iconPNG != nil {
                    preview[app.package] = app
                }
                self.applications.applicationList = list.preview(cached: preview)
            }
            let enriched = try? await client.applicationDetails(device: device, list: list, cached: saved)
            guard !Task.isCancelled, self.deviceSession == session else { return }
            if let enriched {
                self.applications.applicationList = enriched
                self.applications.applicationDetailsUnavailable = enriched.applications.allSatisfy {
                    $0.name == nil && $0.iconPNG == nil
                }
            } else {
                self.applications.applicationDetailsUnavailable = self.applications.applicationList?.applications.allSatisfy {
                    $0.name == nil && $0.iconPNG == nil
                } ?? true
            }
            if let enriched, let fingerprint { await cache.save(enriched, device: fingerprint, previous: saved) }
            guard !Task.isCancelled, self.deviceSession == session else { return }
            self.applications.loadingApplicationDetails = false
            self.applications.detailsWork = nil
        }
    }
}
