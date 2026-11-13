import AppKit
import CoreGraphics

struct MirrorWindowPlacement {
    let visibleFrame: CGRect
    let desktopTop: CGFloat
    private let titleBar: CGFloat = 32
    private let gap: CGFloat = 12

    struct Layout {
        let mainFrame: CGRect
        let mirrorFrame: CGRect
    }

    @MainActor static func prepare(content: CGSize, beside window: NSWindow?) -> [String] {
        guard let screen = window?.screen ?? NSScreen.main,
              let primary = NSScreen.screens.first else { return [] }
        let placement = Self(visibleFrame: screen.visibleFrame, desktopTop: primary.frame.maxY)
        if let window, !window.styleMask.contains(.fullScreen) {
            let minimumWidth = max(window.minSize.width, window.frameRect(
                forContentRect: CGRect(origin: .zero, size: window.contentMinSize)
            ).width)
            if let layout = placement.sideBySide(content: content, mainFrame: window.frame,
                                                 minimumMainWidth: minimumWidth) {
                if layout.mainFrame != window.frame { window.setFrame(layout.mainFrame, display: true) }
                return placement.arguments(for: layout.mirrorFrame)
            }
        }
        if let other = NSScreen.screens.first(where: { $0 !== screen }) {
            return Self(visibleFrame: other.visibleFrame, desktopTop: primary.frame.maxY).centeredArguments(content: content)
        }
        return placement.centeredArguments(content: content)
    }

    func sideBySide(content: CGSize, mainFrame: CGRect, minimumMainWidth: CGFloat) -> Layout? {
        let usable = visibleFrame.insetBy(dx: gap, dy: gap)
        let preferredSize = fittedSize(content, in: CGSize(width: floor(usable.width * 0.4), height: usable.height))
        guard preferredSize.width >= 160, preferredSize.height >= 120 else { return nil }

        func frame(x: CGFloat, size: CGSize, beside main: CGRect) -> CGRect {
            CGRect(x: x.rounded(), y: min(max(main.midY - size.height / 2, usable.minY),
                                         usable.maxY - size.height).rounded(),
                   width: size.width, height: size.height)
        }
        let right = usable.maxX - mainFrame.maxX - gap
        let left = mainFrame.minX - usable.minX - gap
        if right >= preferredSize.width {
            return Layout(mainFrame: mainFrame, mirrorFrame: frame(x: mainFrame.maxX + gap, size: preferredSize, beside: mainFrame))
        }
        if left >= preferredSize.width {
            return Layout(mainFrame: mainFrame, mirrorFrame: frame(x: mainFrame.minX - gap - preferredSize.width,
                                                                  size: preferredSize, beside: mainFrame))
        }

        let mirrorSize = fittedSize(content, in: CGSize(width: min(preferredSize.width, usable.width - minimumMainWidth - gap),
                                                        height: usable.height))
        guard mirrorSize.width >= 160, mirrorSize.height >= 120 else { return nil }

        var main = mainFrame
        main.size.width = min(main.width, usable.width - mirrorSize.width - gap)
        let useRight = right >= left
        let minX = usable.minX + (useRight ? 0 : mirrorSize.width + gap)
        let maxX = usable.maxX - main.width - (useRight ? mirrorSize.width + gap : 0)
        main.origin.x = min(max(main.minX, minX), maxX)
        let mirrorX = useRight ? main.maxX + gap : main.minX - gap - mirrorSize.width
        return Layout(mainFrame: main, mirrorFrame: frame(x: mirrorX, size: mirrorSize, beside: main))
    }

    private func fittedSize(_ content: CGSize, in area: CGSize) -> CGSize {
        guard content.width > 0, content.height > 0, area.width > 0, area.height > titleBar else { return .zero }
        let scale = min(area.width / content.width, (area.height - titleBar) / content.height, 1)
        return CGSize(width: floor(content.width * scale), height: floor(content.height * scale) + titleBar)
    }

    func centeredArguments(content: CGSize) -> [String] {
        let size = fittedSize(content, in: CGSize(width: visibleFrame.width * 0.8, height: visibleFrame.height * 0.8))
        return arguments(for: CGRect(x: visibleFrame.midX - size.width / 2, y: visibleFrame.midY - size.height / 2,
                                     width: size.width, height: size.height))
    }

    func arguments(for frame: CGRect) -> [String] {
        guard frame.width >= 1, frame.height > titleBar else { return [] }
        return ["--window-width", String(Int(frame.width)), "--window-height", String(Int(frame.height - titleBar)),
                "--window-x", String(Int(frame.minX.rounded())),
                "--window-y", String(Int((desktopTop - frame.maxY + titleBar).rounded()))]
    }

    @MainActor static func returnFocusIfNeeded(processID: Int32, to window: NSWindow?) {
        guard let window, window.isVisible,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    static func isVisible(processID: Int32) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains {
            $0[kCGWindowOwnerPID as String] as? Int32 == processID &&
            $0[kCGWindowLayer as String] as? Int == 0 &&
            ($0[kCGWindowAlpha as String] as? Double ?? 0) > 0
        }
    }

    @MainActor static func bringToFront(processID: Int32) {
        guard NSApp.isActive,
              let mirror = NSRunningApplication(processIdentifier: processID),
              !mirror.isActive else { return }
        if mirror.isHidden { _ = mirror.unhide() }
        if #available(macOS 14, *) {
            NSApp.yieldActivation(to: mirror)
            if !mirror.activate(from: .current) { _ = mirror.activate() }
        } else {
            _ = mirror.activate(options: [.activateIgnoringOtherApps])
        }
    }
}
