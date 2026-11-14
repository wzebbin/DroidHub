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

enum MainWindowCloseBehavior: String, CaseIterable {
    case quit, hide, ask

    static let storageKey = "mainWindowCloseBehavior"
    static let defaultValue: Self = .ask

    var label: String {
        switch self {
        case .quit: return "直接退出"
        case .hide: return "隐藏窗口"
        case .ask: return "每次询问"
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
    @AppStorage("includePreviewUpdates") private var includePreviewUpdates = false
    @AppStorage("checkForUpdatesOnLaunch") private var checkForUpdatesOnLaunch = true
    @AppStorage("lastAutomaticUpdateCheck") private var lastAutomaticUpdateCheck: Double = 0
    @State private var consideredLaunchUpdateCheck = false
    @State private var checkingForUpdates = false
    @State private var updateNotice: UpdateNotice?

    var body: some Scene {
        let l10n = L10n(language)
        WindowGroup {
            WorkspaceView(startup: startup)
                .appLanguage(language)
                .environmentObject(model)
                .alert(item: $updateNotice) { $0.alert }
                .onAppear {
                    delegate.onTerminate = { await model.shutdown() }
                    delegate.isRecording = { model.isRecording }
                    delegate.saveRecordingBeforeQuitting = { await model.saveRecordingBeforeQuitting() }
                    delegate.hasActiveTransfers = {
                        model.transfers.items.contains { $0.state.isInQueue } || model.photoExportProgress != nil
                    }
                    startup.record("window_content_ready")
                    if model.online { startup.record("device_online") }
                    let previews = model.videoPreviewFiles
                    Task.detached(priority: .utility) { previews.removeAbandonedSessions() }
                }
                .onChange(of: model.online) { if $0 { startup.record("device_online") } }
                .task(priority: .utility) { await checkForUpdatesAfterLaunch() }
                .frame(minWidth: MainWindowSizing.minimumSize.width, minHeight: MainWindowSizing.minimumSize.height)
                .background(MainWindowSizing(appDelegate: delegate))
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: MainWindowSizing.defaultSize.width, height: MainWindowSizing.defaultSize.height)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button(checkingForUpdates ? l10n.text("正在检查更新…") : l10n.text("检查更新…")) {
                    Task { updateNotice = await checkForUpdates() }
                }
                .disabled(checkingForUpdates)
            }
        }
        Settings {
            ToolSettings(model: model, appearance: $appearance, language: $language,
                         includePreviewUpdates: $includePreviewUpdates, checkForUpdatesOnLaunch: $checkForUpdatesOnLaunch,
                         checkingForUpdates: checkingForUpdates, checkForUpdates: { await checkForUpdates() })
                .appLanguage(language)
                .onChange(of: appearance) { $0.apply() }
        }
    }

    @MainActor
    private func checkForUpdatesAfterLaunch() async {
        guard !consideredLaunchUpdateCheck else { return }
        // Give the main window time to draw before starting the network request.
        do { try await Task.sleep(for: .seconds(1)) }
        catch { return }
        guard !Task.isCancelled, !consideredLaunchUpdateCheck else { return }
        consideredLaunchUpdateCheck = true
        guard checkForUpdatesOnLaunch, !checkingForUpdates else { return }
        let now = Date.now.timeIntervalSince1970
        guard AutomaticUpdateCheck.isDue(lastAttempt: lastAutomaticUpdateCheck, now: now) else { return }
        lastAutomaticUpdateCheck = now
        let notice = await checkForUpdates(automatic: true)
        if !Task.isCancelled, checkForUpdatesOnLaunch, let notice { updateNotice = notice }
    }

    @MainActor
    private func checkForUpdates(automatic: Bool = false) async -> UpdateNotice? {
        guard !checkingForUpdates else { return nil }
        checkingForUpdates = true
        defer { checkingForUpdates = false }
        let includePreviews = includePreviewUpdates

        let bundle = Bundle.main
        guard let repository = bundle.object(forInfoDictionaryKey: "DroidHubReleaseRepository") as? String,
              let source = GitHubReleaseSource(repository: repository),
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return automatic ? nil : UpdateNotice(title: L10n.text("当前构建未配置更新来源"))
        }

        do {
            let result = try await source.check(currentVersion: version, includePreviews: includePreviews)
            return UpdateNotice.forResult(result, currentVersion: version, includePreviews: includePreviews, automatic: automatic)
        } catch {
            return UpdateNotice.forFailure(error, automatic: automatic)
        }
    }
}

enum AutomaticUpdateCheck {
    static func isDue(lastAttempt: TimeInterval, now: TimeInterval) -> Bool {
        lastAttempt == 0 || now - lastAttempt >= 5 * 60 * 60
    }
}

struct UpdateNotice: Identifiable {
    let id = UUID()
    let title: String
    var detail: String?
    var releasePage: URL?

    static func forResult(_ result: GitHubReleaseSource.CheckResult, currentVersion: String,
                          includePreviews: Bool, automatic: Bool) -> Self? {
        switch result {
        case .noPublishedRelease:
            guard !automatic else { return nil }
            return includePreviews
                ? Self(title: L10n.text("暂无可检查的公开版本"))
                : Self(title: L10n.text("暂无正式版本"),
                       detail: L10n.text("可在「设置 → 软件更新」开启「检查开发预览版」。"))
        case .upToDate:
            guard !automatic else { return nil }
            return Self(title: L10n.text("当前已是最新版本"), detail: "DroidHub \(currentVersion)")
        case .updateAvailable(let newVersion, let page, let isPreview):
            let title = isPreview ? "DroidHub {1} 开发预览版已发布" : "DroidHub {1} 已发布"
            return Self(title: L10n.text(title, newVersion),
                        detail: L10n.text("当前版本为 {1}。请在 GitHub 下载适合这台 Mac 的安装包，退出 DroidHub 后替换应用。", currentVersion),
                        releasePage: page)
        }
    }

    static func forFailure(_ error: Error, automatic: Bool) -> Self? {
        automatic ? nil : Self(title: L10n.text("无法检查更新"), detail: L10n.diagnostic(error.localizedDescription))
    }

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

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() async -> Void)?
    var hasActiveTransfers: (() -> Bool)?
    var isRecording: (() -> Bool)?
    var saveRecordingBeforeQuitting: (() async -> Bool)?
    weak var mainWindow: NSWindow?
    private var closePromptOpen = false
    private var confirmedTransferQuit = false
    private var confirmedRecordingQuit = false
    private var terminationPending = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.removeObject(forKey: "mainWindowManualContentSize")
        let saved = UserDefaults.standard.string(forKey: AppAppearance.storageKey)
        (saved.flatMap(AppAppearance.init(rawValue:)) ?? .light).apply()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let mainWindow, !mainWindow.isVisible else { return true }
        mainWindow.makeKeyAndOrderFront(nil)
        return false
    }

    func requestMainWindowClose(_ window: NSWindow) {
        guard !closePromptOpen, !terminationPending else { return }
        let saved = UserDefaults.standard.string(forKey: MainWindowCloseBehavior.storageKey)
        switch saved.flatMap(MainWindowCloseBehavior.init(rawValue:)) ?? .defaultValue {
        case .quit:
            NSApp.terminate(nil)
        case .hide:
            window.orderOut(nil)
        case .ask:
            let transferActive = hasActiveTransfers?() == true
            let recording = isRecording?() == true
            let alert = NSAlert()
            alert.messageText = L10n.text(recording ? "录屏仍在进行" : "关闭 DroidHub 主窗口？")
            if recording {
                alert.informativeText = L10n.text("隐藏窗口后继续录制。退出前会停止录屏并保存 MP4。")
                if transferActive { appendTransferWarning(to: alert) }
                alert.addButton(withTitle: L10n.text("取消")).keyEquivalent = "\r"
                alert.addButton(withTitle: L10n.text("停止录屏并退出"))
                alert.addButton(withTitle: L10n.text("隐藏窗口"))
            } else {
                alert.informativeText = transferActive
                    ? L10n.text("传输队列还有未完成的任务。隐藏窗口可继续传输，退出会中断任务。")
                    : L10n.text("隐藏后可点击程序坞中的 DroidHub 图标重新打开主窗口。")
                alert.addButton(withTitle: L10n.text("隐藏窗口"))
                alert.addButton(withTitle: L10n.text("退出 DroidHub"))
                alert.addButton(withTitle: L10n.text("取消")).keyEquivalent = "\u{1b}"
            }
            closePromptOpen = true
            let response = alert.runModal()
            closePromptOpen = false
            if response == (recording ? .alertThirdButtonReturn : .alertFirstButtonReturn) {
                window.orderOut(nil)
            } else if response == .alertSecondButtonReturn {
                confirmedTransferQuit = transferActive
                confirmedRecordingQuit = recording
                NSApp.terminate(nil)
                confirmedTransferQuit = false
                confirmedRecordingQuit = false
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !closePromptOpen else { return .terminateCancel }
        guard !terminationPending else { return .terminateLater }
        let recording = !confirmedRecordingQuit && isRecording?() == true
        let transferActive = !confirmedTransferQuit && hasActiveTransfers?() == true
        if recording || transferActive {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.text(recording ? "录屏仍在进行" : "传输尚未完成")
            if recording { alert.informativeText = L10n.text("退出前会停止录屏并保存 MP4。") }
            if transferActive { appendTransferWarning(to: alert) }
            alert.addButton(withTitle: L10n.text("取消")).keyEquivalent = "\r"
            alert.addButton(withTitle: L10n.text(recording ? "停止录屏并退出" : "退出 DroidHub"))
            closePromptOpen = true
            let response = alert.runModal()
            closePromptOpen = false
            guard response == .alertSecondButtonReturn else { return .terminateCancel }
        }
        terminationPending = true
        Task { @MainActor in
            if await saveRecordingBeforeQuitting?() == false {
                terminationPending = false
                sender.reply(toApplicationShouldTerminate: false)
                mainWindow?.makeKeyAndOrderFront(nil)
                return
            }
            await onTerminate?()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func appendTransferWarning(to alert: NSAlert) {
        let warning = L10n.text("退出 DroidHub 会中断未完成的任务。")
        alert.informativeText = [alert.informativeText, warning].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
