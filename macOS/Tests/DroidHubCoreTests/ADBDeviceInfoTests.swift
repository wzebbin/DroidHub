import Foundation
import XCTest
@testable import DroidHubCore

final class ADBDeviceInfoTests: XCTestCase {
    func testDeviceSnapshotParsesDiskMemoryDisplayAndScaledBattery() throws {
        let info = AndroidDeviceInfo(output: """
            @properties
            ro.product.marketname=
            ro.product.vendor.marketname=测试手机
            ro.build.version.release=17
            ro.build.display.id=Example=Build
            ro.product.cpu.abi=arm64-v8a
            @storage
            Filesystem 1K-blocks Used Available Use% Mounted on
            /dev/block/dm-1 1000 250 700 27% /data/user/0
            @memory
            MemTotal: 8000 kB
            MemAvailable: 4000 kB
            @display
            Physical size: 1200x2670
            Override size: 1080x2400
            Physical density: 520
            @battery
            present: true
            status: 3
            level: 4
            scale: 5
            temperature: 364
            status: 5
            """)
        XCTAssertEqual(info.marketName, "测试手机")
        XCTAssertEqual(info.build, "Example=Build")
        XCTAssertEqual(info.architecture, "arm64-v8a")
        XCTAssertEqual(info.storage?.totalBytes, 1_024_000)
        XCTAssertEqual(info.storage?.availableBytes, 716_800)
        XCTAssertEqual(info.storage?.usedFraction, 0.25)
        XCTAssertEqual(info.totalMemory, 8_192_000)
        XCTAssertEqual(info.availableMemory, 4_096_000)
        XCTAssertEqual(info.screenSize, "1200 × 2670")
        XCTAssertEqual(info.screenDensity, 520)
        XCTAssertEqual(info.battery?.chargeFraction, 0.8)
        XCTAssertEqual(info.battery?.status, .discharging)
        XCTAssertEqual(info.battery?.temperatureCelsius, 36.4)
    }

    func testPartialOrInvalidDataDoesNotBecomeZeroCapacityOrCharge() {
        let info = AndroidDeviceInfo(output: """
            @properties
            ro.product.model=Emulator
            @storage
            /dev/null 0 0 0 0% /data
            @memory
            MemTotal: 20 kB
            MemAvailable: 40 kB
            @display
            Physical size: 1x2xinvalid
            @battery
            present: false
            level: 0
            scale: 100
            """)
        XCTAssertEqual(info.model, "Emulator")
        XCTAssertNil(info.storage)
        XCTAssertNil(info.availableMemory)
        XCTAssertNil(info.screenSize)
        XCTAssertNil(info.battery)
    }

    func testSectionHeadersWithoutFieldsFailDeviceRefresh() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let script = "#!/bin/sh\nprintf '@properties\\n@storage\\n@memory\\n@display\\n@battery\\n'\n"
        try Data(script.utf8).write(to: fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        do {
            _ = try await ADBClient(executable: fixture.path).deviceInfo(serial: "fixture")
            XCTFail("An empty device response must fail refresh")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("未返回可读取的设备信息"))
        }
    }

    func testMirrorDisplayCanSkipNameLookupAndStillReadDimensions() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let script = #"""
        #!/bin/sh
        getprop() {
          case "$1" in
            ro.product.vendor.marketname) printf 'Fixture Phone\n' ;;
          esac
        }
        dumpsys() { printf '  Display: mDisplayId=0\n    cur=1080x2400\n'; }
        eval "set -- $7"
        eval "$1"
        """#
        try Data(script.utf8).write(to: fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let client = ADBClient(executable: fixture.path)
        let device = try XCTUnwrap(AndroidDevice.parse("fixture device").first)
        let name = try await client.deviceDisplayName(for: device)
        let named = try await client.mirrorDisplay(serial: device.serial)
        let sizeOnly = try await client.mirrorDisplay(serial: device.serial, includeName: false)
        XCTAssertEqual(name, "Fixture Phone")
        XCTAssertEqual(named.name, name)
        XCTAssertNil(sizeOnly.name)
        XCTAssertEqual(named.size, CGSize(width: 1080, height: 2400))
        XCTAssertEqual(sizeOnly.size, named.size)
    }

    func testDeviceSnapshotOnPhone() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let executable = env["DROIDHUB_DEVICE_TEST_ADB"],
              let serial = env["DROIDHUB_DEVICE_TEST_SERIAL"] else { throw XCTSkip("No device connected for this test") }
        let info = try await ADBClient(executable: executable).deviceInfo(serial: serial)
        XCTAssertNotNil(info.model)
        XCTAssertNotNil(info.androidVersion)
        XCTAssertNotNil(info.securityPatch)
        XCTAssertNotNil(info.screenSize)
        XCTAssertNotNil(info.storage)
        XCTAssertNotNil(info.totalMemory)
        XCTAssertNotNil(info.battery?.chargeFraction)
    }
}
