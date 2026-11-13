import SwiftUI
import AppKit
import DroidHubCore
import OSLog

@MainActor
final class StartupMetrics {
    private let start = DispatchTime.now().uptimeNanoseconds
    private let logger = Logger(subsystem: "io.droidhub.mac", category: "Startup")
    private var recorded: Set<String> = []

    func record(_ milestone: String) {
        guard recorded.insert(milestone).inserted else { return }
        let milliseconds = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        logger.notice("\(milestone, privacy: .public) \(milliseconds, privacy: .public) ms")
    }
}

enum AppAppearance: String {
    case light, dark, system

    static let storageKey = "appearance"

    @MainActor
    func apply() {
        switch self {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
        }
    }
}

@main
struct DroidHubApp: App {
    private let startup = StartupMetrics()
    @StateObject private var model = HubModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .light
    @AppStorage(AppLanguage.preferenceKey) private var language: AppLanguage = .simplifiedChinese
    @State private var checkingForUpdates = false
    @State private var updateNotice: UpdateNotice?

    private struct UpdateNotice: Identifiable {
        let id = UUID()
        let title: String
        var detail: String?
        var releasePage: URL?

        var alert: Alert {
            let message = detail.map { Text($0) }
            if let releasePage {
                return Alert(title: Text(title), message: message,
                             primaryButton: .default(Text(L10n.text("打开 GitHub 发布页"))) { NSWorkspace.shared.open(releasePage) },
                             secondaryButton: .cancel(Text(L10n.text("稍后"))))
            }
            return Alert(title: Text(title), message: message, dismissButton: .default(Text(L10n.text("好"))))
        }
    }

    var body: some Scene {
        let l10n = L10n(language)
        WindowGroup {
            WorkspaceView(startup: startup)
                .appLanguage(language)
                .environmentObject(model)
                .alert(item: $updateNotice) { $0.alert }
                .onAppear {
                    delegate.onTerminate = { await model.shutdown() }
                    startup.record("window_content_ready")
                    if model.online { startup.record("device_online") }
                    let previews = model.videoPreviewFiles
                    Task.detached(priority: .utility) { previews.removeAbandonedSessions() }
                }
                .onChange(of: model.online) { if $0 { startup.record("device_online") } }
                .frame(minWidth: MainWindowSizing.minimumSize.width, minHeight: MainWindowSizing.minimumSize.height)
                .background(MainWindowSizing())
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: MainWindowSizing.defaultSize.width, height: MainWindowSizing.defaultSize.height)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button(checkingForUpdates ? l10n.text("正在检查更新…") : l10n.text("检查更新…")) {
                    Task { await checkForUpdates() }
                }
                .disabled(checkingForUpdates)
            }
        }
        Settings {
            ToolSettings(model: model, appearance: $appearance, language: $language)
                .appLanguage(language)
                .onChange(of: appearance) { $0.apply() }
        }
    }

    @MainActor
    private func checkForUpdates() async {
        guard !checkingForUpdates else { return }
        checkingForUpdates = true
        defer { checkingForUpdates = false }

        let bundle = Bundle.main
        guard let repository = bundle.object(forInfoDictionaryKey: "DroidHubReleaseRepository") as? String,
              let source = GitHubReleaseSource(repository: repository),
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            updateNotice = UpdateNotice(title: L10n.text("当前构建未配置更新来源"))
            return
        }

        do {
            switch try await source.check(currentVersion: version) {
            case .noPublishedRelease:
                updateNotice = UpdateNotice(title: L10n.text("暂无可检查的公开版本"),
                                            detail: L10n.text("请确认 GitHub 发布仓库已公开，并且已有正式 Release。"))
            case .upToDate:
                updateNotice = UpdateNotice(title: L10n.text("当前已是最新版本"), detail: "DroidHub \(version)")
            case .updateAvailable(let newVersion, let page):
                updateNotice = UpdateNotice(title: L10n.text("DroidHub {1} 已发布", newVersion),
                                            detail: L10n.text("当前版本为 {1}。请在 GitHub 下载适合这台 Mac 的安装包，退出 DroidHub 后替换应用。", version),
                                            releasePage: page)
            }
        } catch {
            updateNotice = UpdateNotice(title: L10n.text("无法检查更新"), detail: L10n.diagnostic(error.localizedDescription))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() async -> Void)?
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.removeObject(forKey: "mainWindowManualContentSize")
        let saved = UserDefaults.standard.string(forKey: AppAppearance.storageKey)
        (saved.flatMap(AppAppearance.init(rawValue:)) ?? .light).apply()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await onTerminate?()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
