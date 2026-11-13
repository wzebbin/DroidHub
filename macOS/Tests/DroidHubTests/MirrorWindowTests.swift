import CoreGraphics
import XCTest
@testable import DroidHub

final class MirrorWindowTests: XCTestCase {
    func testNarrowDisplayKeepsMainWindowUsableAndDoesNotOverlapPortraitMirror() throws {
        let visible = CGRect(x: 0, y: 40, width: 1024, height: 700)
        let placement = MirrorWindowPlacement(visibleFrame: visible, desktopTop: 768)
        let main = CGRect(x: 0, y: 50, width: 1024, height: 660)
        let layout = try XCTUnwrap(placement.sideBySide(content: CGSize(width: 1200, height: 2670),
                                                        mainFrame: main, minimumMainWidth: 820))
        XCTAssertEqual(layout.mainFrame.width, 820)
        XCTAssertEqual(layout.mainFrame.height, main.height)
        XCTAssertFalse(layout.mainFrame.intersects(layout.mirrorFrame))
        XCTAssertTrue(visible.contains(layout.mirrorFrame))
    }

    func testUsesLeftSideWithoutMovingMainWindow() throws {
        let placement = MirrorWindowPlacement(visibleFrame: CGRect(x: 0, y: 40, width: 1440, height: 830),
                                              desktopTop: 900)
        let main = CGRect(x: 610, y: 60, width: 820, height: 700)
        let layout = try XCTUnwrap(placement.sideBySide(content: CGSize(width: 1200, height: 2670),
                                                        mainFrame: main, minimumMainWidth: 820))
        XCTAssertEqual(layout.mainFrame, main)
        XCTAssertEqual(main.minX - layout.mirrorFrame.maxX, 12)
    }

    func testLandscapeFitsByWidthOnDisplayToLeftOfPrimary() {
        let placement = MirrorWindowPlacement(visibleFrame: CGRect(x: -1024, y: 0, width: 1024, height: 768),
                                              desktopTop: 900)
        XCTAssertEqual(placement.centeredArguments(content: CGSize(width: 2670, height: 1200)),
                       ["--window-width", "819", "--window-height", "368", "--window-x", "-922", "--window-y", "348"])
    }
}
