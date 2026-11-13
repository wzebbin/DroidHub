import Foundation
import XCTest
@testable import DroidHubCore

final class ADBApplicationExportTests: XCTestCase {
    func testAPKPathListKeepsEverySplitAndRejectsAmbiguousOutput() throws {
        let paths = [
            "/data/app/pkg/split_config.xxhdpi.apk",
            "/data/app/pkg/base.apk",
            "/data/app/pkg/split_feature.apk",
        ]
        let valid = paths.map { "package:" + $0 }.joined(separator: "\r\n")
        XCTAssertEqual(try ADBClient.parseApplicationAPKPaths(Data(valid.utf8)), paths.sorted())
        for invalid in ["", "Error: package not found", "package:base.apk", "package:/app/../base.apk",
                        "package:/app/base.apk\npackage:/other/BASE.apk",
                        "package:/app/base.apk\nError: failed reading splits"] {
            XCTAssertThrowsError(try ADBClient.parseApplicationAPKPaths(Data(invalid.utf8)), invalid)
        }
    }

    func testIncompleteDownloadDoesNotReplaceExistingExport() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let fake = root.appendingPathComponent("fake-adb")
        let script = """
        #!/bin/sh
        case "$3" in
          shell)
            case "$*" in
              *get-current-user*) echo 0 ;;
              *'pm path'*) printf 'package:/app/base.apk\\npackage:/app/split_feature.apk\\n' ;;
              *'stat -c'*) printf '4:1:1\\n4:1:2\\n' ;;
              *) exit 2 ;;
            esac ;;
          pull)
            case "$4" in
              */base.apk) printf 'abcd' > "$5" ;;
              */split_feature.apk) printf 'ab' > "$5" ;;
              *) exit 3 ;;
            esac ;;
          *) exit 4 ;;
        esac
        """
        try Data(script.utf8).write(to: fake)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let destination = root.appendingPathComponent("app.zip")
        let original = Data("existing archive".utf8)
        try original.write(to: destination)

        let client = ADBClient(executable: fake.path)
        let device = try XCTUnwrap(AndroidDevice.parse("List of devices attached\nphone device transport_id:42\n").first)
        let export = try await client.prepareApplicationExport(device: device, package: "example.app", user: 0)
        do {
            try await client.exportApplication(export, to: destination, replaceExisting: true)
            XCTFail("Accepted incomplete split APK")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("split_feature.apk"))
        }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(Set(try manager.contentsOfDirectory(atPath: root.path)), ["fake-adb", "app.zip"])
    }

    func testSingleAndSplitExportsOnPhone() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let adb = env["DROIDHUB_APP_TEST_ADB"], let splitPackage = env["DROIDHUB_APP_TEST_SPLIT"],
              let serials = env["DROIDHUB_APP_TEST_SERIALS"] else {
            throw XCTSkip("No APK export fixture")
        }
        let client = ADBClient(executable: adb)
        let devices = try await client.devices()
        let requested = Set(serials.split(separator: ",").map(String.init))
        let targets = devices.filter { $0.isOnline && requested.contains($0.serial) }
        XCTAssertFalse(requested.isEmpty)
        XCTAssertEqual(Set(targets.map(\.serial)), requested)
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }

        for device in targets {
            let user = try await client.currentApplicationUser(device: device)
            for (package, ext) in [("com.android.settings", "apk"), (splitPackage, "zip")] {
                let export = try await client.prepareApplicationExport(device: device, package: package, user: user)
                XCTAssertEqual(export.fileExtension, ext)
                let directory = root.appendingPathComponent(UUID().uuidString)
                try manager.createDirectory(at: directory, withIntermediateDirectories: false)
                let destination = directory.appendingPathComponent("\(package).\(ext)")
                try await client.exportApplication(export, to: destination, replaceExisting: false)
                let contents = directory.appendingPathComponent("extracted")
                if ext == "zip" {
                    let members = try await ProcessRunner.run("/usr/bin/unzip", ["-Z1", destination.path])
                    let names = export.paths.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted()
                    XCTAssertEqual(String(decoding: members, as: UTF8.self)
                        .split(whereSeparator: \.isNewline).map(String.init).sorted(), names)
                    _ = try await ProcessRunner.run("/usr/bin/unzip", ["-t", destination.path])
                    _ = try await ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", destination.path, contents.path])
                    XCTAssertEqual(Set(try manager.contentsOfDirectory(atPath: contents.path)),
                                   Set(export.paths.map { URL(fileURLWithPath: $0).lastPathComponent }))
                }
                let paths = export.paths.map(Shell.quote).joined(separator: " ")
                let remote = try await client.shell(device: device, script: "sha256sum \(paths)", timeout: 180)
                let hashes = String(decoding: remote, as: UTF8.self).split(whereSeparator: \.isNewline)
                    .compactMap { $0.split(separator: " ").first }
                XCTAssertEqual(hashes.count, export.apkCount)
                for (path, expected) in zip(export.paths, hashes) {
                    let local = ext == "apk" ? destination : contents.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
                    let output = try await ProcessRunner.run("/usr/bin/shasum", ["-a", "256", local.path])
                    XCTAssertEqual(String(decoding: output, as: UTF8.self).split(separator: " ").first, expected)
                }
                print("Verified \(ext) export (\(export.apkCount) APKs) over \(device.isWireless ? "Wi-Fi" : "USB")")
            }
        }
    }
}
