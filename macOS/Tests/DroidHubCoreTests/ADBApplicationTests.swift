import Foundation
import ImageIO
import XCTest
@testable import DroidHubCore

final class ADBApplicationTests: XCTestCase {
    func testApplicationDetailsSortIndependentlyAndKeepMissingValuesLast() throws {
        let list = try ADBClient.parseApplications(Data("0\npackage:app.alpha\npackage:app.beta\npackage:app.gamma\n--\n".utf8))
        let stamp = String(repeating: "a", count: 22)
        let label = Data("示例/应用".utf8).base64EncodedString()
        let version = Data("2.3:beta".utf8).base64EncodedString()
        let output = Data([
            ["app.alpha", label, "", version, "400", "", stamp, "fresh", "1730000000000", "1740000000000", "4294967296", "24", "36", "2"],
            ["app.beta", "", "", "", "200", "", stamp, "fresh", "540000000", "1750000000000", "9", "0", "33", "0"],
            ["app.gamma", "", "", "", "", "", stamp, "fresh"]
        ].map { $0.joined(separator: "\t") }.joined(separator: "\n").utf8)
        let apps = ADBClient.mergeApplicationDetails(output, into: list).applications
        let alpha = try XCTUnwrap(apps.first { $0.package == "app.alpha" })
        XCTAssertEqual(alpha.details?.installedAt, Date(timeIntervalSince1970: 1_730_000_000))
        XCTAssertEqual(alpha.details?.versionCode, 4_294_967_296)
        XCTAssertEqual(alpha.details?.minimumSDK, 24)
        XCTAssertEqual(alpha.details?.targetSDK, 36)
        XCTAssertEqual(alpha.details?.splitCount, 2)
        XCTAssertEqual(alpha.exportFilenameStem, "示例_应用 - 2.3_beta")
        XCTAssertEqual(AndroidApplicationSort.recentInstall.ordered(apps).map(\.package), ["app.alpha", "app.beta", "app.gamma"])
        XCTAssertEqual(AndroidApplicationSort.recentUpdate.ordered(apps).map(\.package), ["app.beta", "app.alpha", "app.gamma"])
        XCTAssertEqual(AndroidApplicationSort.largestAPK.ordered(apps).map(\.package), ["app.alpha", "app.beta", "app.gamma"])
        let beta = try XCTUnwrap(apps.first { $0.package == "app.beta" })
        XCTAssertNil(beta.details?.installedAt)
        XCTAssertNil(beta.details?.minimumSDK)
        XCTAssertEqual(beta.details?.splitCount, 0)
        XCTAssertEqual(beta.exportFilenameStem, "app.beta - 9")
        XCTAssertNil(apps.first { $0.package == "app.gamma" }?.details)
    }

    func testIncrementalMetadataValidatesStampsAndPersistsOnlyReusableEntries() async throws {
        let list = try ADBClient.parseApplications(Data("0\npackage:io.example.same\npackage:io.example.updated\n--\npackage:android\n".utf8))
        let oldStamp = String(repeating: "a", count: 22)
        let newStamp = String(repeating: "b", count: 22)
        let label = Data("新版名称".utf8).base64EncodedString()
        let saved = [
            "io.example.same": AndroidApplication(package: "io.example.same", isSystem: false, name: "缓存名称",
                                                   launcherComponent: "io.example.same/.Old", metadataStamp: oldStamp),
            "io.example.updated": AndroidApplication(package: "io.example.updated", isSystem: false,
                                                      name: "旧名称", metadataStamp: oldStamp)
        ]
        let preview = list.preview(cached: saved)
        XCTAssertEqual(preview.applications.first { $0.package == "io.example.same" }?.name, "缓存名称")
        XCTAssertNil(preview.applications.first { $0.package == "io.example.same" }?.launcherComponent)

        let output = Data([
            ["io.example.same", "", "", "", "200", "io.example.same/.New", oldStamp, "hit"],
            ["io.example.updated", label, "", "", "300", "", newStamp, "fresh"],
            ["android", "", "", "", "", "", oldStamp, "retry"]
        ].map { $0.joined(separator: "\t") }.joined(separator: "\n").utf8)
        let updated = ADBClient.mergeApplicationDetails(output, into: list, cached: saved)
        XCTAssertEqual(updated.applications.first { $0.package == "io.example.same" }?.launcherComponent, "io.example.same/.New")
        XCTAssertEqual(updated.applications.first { $0.package == "io.example.updated" }?.name, "新版名称")
        XCTAssertNil(updated.applications.first { $0.package == "android" }?.metadataStamp)
        let stale = Data(["io.example.same", "", "", "", "", "", newStamp, "hit"].joined(separator: "\t").utf8)
        XCTAssertNil(ADBClient.mergeApplicationDetails(stale, into: list, cached: saved)
            .applications.first { $0.package == "io.example.same" }?.name)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ApplicationMetadataCache(directory: root)
        let fingerprint = String(repeating: "a", count: 64)
        await cache.save(updated, device: fingerprint, previous: [:])
        let reopened = ApplicationMetadataCache(directory: root)
        let entries = await reopened.read(device: fingerprint, user: 0)
        let otherUser = await reopened.read(device: fingerprint, user: 10)
        let otherDevice = await reopened.read(device: String(repeating: "b", count: 64), user: 0)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries["io.example.updated"]?.metadataStamp, newStamp)
        XCTAssertTrue(otherUser.isEmpty)
        XCTAssertTrue(otherDevice.isEmpty)
    }

    func testApplicationDetailsKeepPackageIdentityAndMatchLocalizedName() throws {
        let list = try ADBClient.parseApplications(Data("0\npackage:io.example.app\n--\npackage:android\n".utf8))
        let label = Data("相册".utf8).base64EncodedString()
        let output = Data("io.example.app\t\(label)\tinvalid\nother.app\t\(label)\t\n".utf8)
        let enriched = ADBClient.mergeApplicationDetails(output, into: list)
        let app = try XCTUnwrap(enriched.applications.first { $0.matches("相册") })
        XCTAssertEqual(app.package, "io.example.app")
        XCTAssertTrue(app.matches("EXAMPLE"))
        XCTAssertNil(app.iconPNG)
        XCTAssertEqual(enriched.applications.count, 2)
        XCTAssertEqual(enriched.applications.first { $0.isSystem }?.displayName, "android")
    }

    func testApplicationDetailsOnPhone() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let adb = env["DROIDHUB_APP_TEST_ADB"], let serial = env["DROIDHUB_APP_TEST_SERIAL"],
              let helper = env["DROIDHUB_APP_TEST_HELPER"] else { throw XCTSkip("No app metadata fixture") }
        let client = ADBClient(executable: adb)
        let devices = try await client.devices()
        let device = try XCTUnwrap(devices.first { $0.serial == serial && $0.isOnline })
        let list = try await client.applications(device: device)
        let enriched = try await client.applicationDetails(device: device, list: list, helper: URL(fileURLWithPath: helper))
        let settings = try XCTUnwrap(enriched.applications.first { $0.package == "com.android.settings" })
        let label = try XCTUnwrap(settings.name)
        XCTAssertTrue(settings.matches(label))
        let data = try XCTUnwrap(settings.iconPNG)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 48)
        XCTAssertEqual(image.height, 48)
        XCTAssertNotNil(settings.version)
        XCTAssertGreaterThan(settings.apkBytes ?? 0, 0)
        XCTAssertNotNil(settings.launcherComponent)
        XCTAssertTrue(enriched.applications.contains {
            !$0.isSystem && $0.details?.installedAt != nil && $0.details?.updatedAt != nil
        })
        XCTAssertNotNil(settings.details?.versionCode)
        XCTAssertGreaterThan(settings.details?.minimumSDK ?? 0, 0)
        XCTAssertGreaterThan(settings.details?.targetSDK ?? 0, 0)
        XCTAssertNotNil(settings.details?.splitCount)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = String(repeating: "a", count: 64)
        await ApplicationMetadataCache(directory: directory).save(enriched, device: key, previous: [:])
        let saved = await ApplicationMetadataCache(directory: directory).read(device: key, user: list.user)
        XCTAssertEqual(saved[settings.package]?.iconPNG, data)
        let warm = try await client.applicationDetails(device: device, list: list, cached: saved,
                                                       helper: URL(fileURLWithPath: helper))
        XCTAssertEqual(warm.applications.first { $0.package == settings.package }, settings)
        if env["DROIDHUB_APP_TEST_LAUNCH_SETTINGS"] == "1" {
            try await client.launchApplication(device: device, application: settings, user: list.user)
        }
        XCTAssertEqual(Set(enriched.applications.map(\.package)), Set(list.applications.map(\.package)))
        print("Verified app metadata over \(device.isWireless ? "Wi-Fi" : "USB")")
    }

    func testApplicationMetadataAcceptsOnlyLauncherInSamePackage() throws {
        let list = try ADBClient.parseApplications(Data("0\npackage:io.example.app\n--\npackage:android\n".utf8))
        let version = Data("1.2.3".utf8).base64EncodedString()
        let output = Data("io.example.app\t\t\t\(version)\t1234\tio.example.app/.Main\nandroid\t\t\t\t-1\tother.app/.Main\n".utf8)
        let enriched = ADBClient.mergeApplicationDetails(output, into: list)
        let app = try XCTUnwrap(enriched.applications.first { !$0.isSystem })
        XCTAssertEqual(app.version, "1.2.3")
        XCTAssertEqual(app.apkBytes, 1234)
        XCTAssertEqual(app.launcherComponent, "io.example.app/.Main")
        XCTAssertNil(enriched.applications.first { $0.isSystem }?.apkBytes)
        XCTAssertNil(enriched.applications.first { $0.isSystem }?.launcherComponent)
    }

    func testPackageListKeepsSystemPackagesReadOnly() throws {
        let output = Data("""
            10
            package:io.example.app
            package:io.example.duplicate
            --
            package:android
            package:io.example.duplicate
            """.utf8)
        let list = try ADBClient.parseApplications(output)
        XCTAssertEqual(list.user, 10)
        XCTAssertEqual(list.applications.map(\.package), ["android", "io.example.app", "io.example.duplicate"])
        XCTAssertEqual(list.applications.map(\.isSystem), [true, false, true])
        XCTAssertThrowsError(try ADBClient.parseApplications(Data("0\npackage:io.example.app".utf8)))
    }

    func testInstallAndUninstallFixtureOnPhone() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let adb = env["DROIDHUB_APP_TEST_ADB"], let serial = env["DROIDHUB_APP_TEST_SERIAL"],
              let path = env["DROIDHUB_APP_TEST_APK"], let package = env["DROIDHUB_APP_TEST_PACKAGE"],
              package.hasPrefix("io.droidhub.qa.") else { throw XCTSkip("No dedicated app fixture") }
        let client = ADBClient(executable: adb)
        let devices = try await client.devices()
        let device = try XCTUnwrap(devices.first { $0.serial == serial && $0.isOnline })
        let initial = try await client.applications(device: device)
        XCTAssertTrue(initial.applications.contains { $0.package == "android" && $0.isSystem })
        guard !initial.applications.contains(where: { $0.package == package }) else {
            return XCTFail("The fixture package already exists")
        }
        let apk = URL(fileURLWithPath: path)
        do {
            try await client.installApplication(device: device, apk: apk, user: initial.user)
            let installed = try await client.applications(device: device)
            XCTAssertTrue(installed.applications.contains { $0.package == package && !$0.isSystem })
            try await client.uninstallApplication(device: device, package: package, user: initial.user)
            let removed = try await client.applications(device: device)
            XCTAssertFalse(removed.applications.contains { $0.package == package })
        } catch {
            try? await client.uninstallApplication(device: device, package: package, user: initial.user)
            throw error
        }
        print("Verified app list, installation and uninstall over \(device.isWireless ? "Wi-Fi" : "USB")")
    }
}
