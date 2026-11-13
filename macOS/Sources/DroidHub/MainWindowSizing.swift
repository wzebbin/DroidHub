import AppKit
import SwiftUI

struct MainWindowSizing: NSViewRepresentable {
    static let defaultSize = CGSize(width: 1000, height: 660)
    static let minimumSize = CGSize(width: 820, height: 620)

    func makeNSView(context: Context) -> WindowSizingView { WindowSizingView() }

    func updateNSView(_ view: WindowSizingView, context: Context) {}

    final class WindowSizingView: NSView {
        private weak var configuredWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, configuredWindow !== window else { return }
            configuredWindow = window
            window.isRestorable = false
            // SwiftUI installs its initial window geometry during attachment.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.place(window)
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
