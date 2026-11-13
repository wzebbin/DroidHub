import XCTest
@testable import DroidHubCore

final class BatchRenameTests: XCTestCase {
    private func item(_ name: String, directory: Bool = false) -> DeviceFile {
        DeviceFile(name: name, path: "/sdcard/\(name)", isDirectory: directory, size: 1)
    }

    func testNumberingKeepsOriginalExtensionsAndUsesSelectionOrder() {
        let selection = [item("原 图.JpG"), item(".hidden"), item("目录.v1", directory: true), item("报告.txt.txt")]
        let plan = BatchRenamePlan(selection: selection, directory: selection, rule: .number(prefix: "归档 "))
        XCTAssertEqual(plan.rows.map(\.name), ["归档 001.JpG", "归档 002", "归档 003", "归档 004.txt"])
        XCTAssertTrue(plan.canApply)
    }

    func testPreviewCatchesCollisionsAndInvalidNamesBeforeApplying() {
        let first = item("ab.TXT")
        let second = item("aab.TXT")
        let selection = [first, second]
        let duplicate = BatchRenamePlan(selection: selection, directory: selection,
                                        rule: .replace(find: "a", replacement: ""))
        XCTAssertEqual(duplicate.rows.map(\.issue), [.duplicateResult, .duplicateResult])
        let occupied = BatchRenamePlan(selection: selection, directory: selection + [item("新 ab.txt")],
                                       rule: .affixes(prefix: "新 ", suffix: ""))
        XCTAssertEqual(occupied.rows.map(\.issue), [.existingName, nil])
        XCTAssertFalse(occupied.canApply)
        let invalid = BatchRenamePlan(selection: selection, directory: selection, rule: .number(prefix: "bad/"))
        XCTAssertEqual(invalid.rows.map(\.issue), [.invalidName, .invalidName])
        let stale = BatchRenamePlan(selection: selection, directory: [first], rule: .number(prefix: ""))
        XCTAssertEqual(stale.rows.last?.issue, .sourceChanged)
        let noop = BatchRenamePlan(selection: selection, directory: selection, rule: .replace(find: "not found", replacement: "x"))
        XCTAssertFalse(noop.canApply)
    }
}
