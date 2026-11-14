import AppKit
import SwiftUI

struct MainWindowSizing: NSViewRepresentable {
    static let defaultSize = CGSize(width: 1000, height: 660)
    static let minimumSize = CGSize(width: 820, height: 620)

    let appDelegate: AppDelegate

    func makeNSView(context: Context) -> WindowSizingView {
        let view = WindowSizingView()
        view.closeDelegate.appDelegate = appDelegate
        return view
    }

    func updateNSView(_ view: WindowSizingView, context: Context) {}

    final class WindowSizingView: NSView {
        fileprivate let closeDelegate = WindowCloseDelegate()
        private weak var configuredWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard configuredWindow !== window else { return }
            if let oldWindow = configuredWindow, oldWindow.delegate === closeDelegate {
                oldWindow.delegate = closeDelegate.original
            }
            configuredWindow = window
            guard let window else { return }
            closeDelegate.appDelegate?.mainWindow = window
            window.isRestorable = false
            // Wait for SwiftUI to install its window geometry and delegate.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.place(window)
                self.closeDelegate.original = window.delegate
                window.delegate = self.closeDelegate
            }
        }

        private func place(_ window: NSWindow) {
            guard let screen = window.screen ?? NSScreen.main else { return }
            let preferred = window.frameRect(forContentRect: CGRect(origin: .zero, size: MainWindowSizing.defaultSize))
            let visible = screen.visibleFrame
            let width = min(preferred.width, visible.width)
            let height = min(preferred.height, visible.height)
            window.setFrame(CGRect(x: (visible.midX - width / 2).rounded(),
                                   y: (visible.midY - height / 2).rounded(),
                                   width: width, height: height), display: true)
        }
    }
}

@MainActor
private final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    weak var appDelegate: AppDelegate?
    weak var original: NSWindowDelegate?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard original?.windowShouldClose?(sender) != false else { return false }
        guard let appDelegate else { return true }
        appDelegate.requestMainWindowClose(sender)
        return false
    }

    // Preserve SwiftUI's delegate callbacks for all other window events.
    override nonisolated func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || MainActor.assumeIsolated {
            original?.responds(to: selector) == true
        }
    }

    override nonisolated func forwardingTarget(for selector: Selector!) -> Any? {
        MainActor.assumeIsolated { original } ?? super.forwardingTarget(for: selector)
    }
}
