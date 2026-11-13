import XCTest
@testable import DroidHubCore

final class ADBWirelessTests: XCTestCase {
    func testConnectionIdentityKeepsHardwareAndUserIndependent() {
        let normal = ADBClient.parseConnectionIdentity(Data("Primary123\nBoot456\n10\n".utf8))
        XCTAssertEqual(normal.hardware, "Primary123")
        XCTAssertEqual(normal.user, 10)

        let fallback = ADBClient.parseConnectionIdentity(Data("\nBoot456\n0\n".utf8))
        XCTAssertEqual(fallback.hardware, "Boot456")
        XCTAssertEqual(fallback.user, 0)

        let userOnly = ADBClient.parseConnectionIdentity(Data("unknown\n\n12345\n".utf8))
        XCTAssertNil(userOnly.hardware)
        XCTAssertEqual(userOnly.user, 12345)

        let hardwareOnly = ADBClient.parseConnectionIdentity(Data("Primary123\nBoot456\n".utf8))
        XCTAssertEqual(hardwareOnly.hardware, "Primary123")
        XCTAssertNil(hardwareOnly.user)
    }

    func testEndpointAndDiscovery() {
        XCTAssertEqual(ADBEndpoint("[2001:0db8::1]:37123")?.description, "[2001:db8::1]:37123")
        XCTAssertEqual(ADBEndpoint(" 192.168.1.8:37123\n")?.description, "192.168.1.8:37123")
        XCTAssertNil(ADBEndpoint("192.168.1.8:65536"))
        let services = ADBWirelessService.parse("""
        List of discovered mdns services
        studio-123 _adb-tls-pairing._tcp 192.168.1.8:37201
        adb-alpha-Z9 _adb-tls-connect._tcp 192.168.1.8:37123
        adb-alpha-Z9 _adb-tls-connect._tcp 192.168.1.8:37123
        adb-beta-T1 _adb-tls-connect._tcp 192.168.1.8:37125
        unrelated _adb._tcp 192.168.1.8:5555
        """)
        XCTAssertEqual(services.count, 3)
        XCTAssertNil(ADBWirelessService.connection(in: services, guid: nil, host: "192.168.1.8"))
        XCTAssertEqual(ADBWirelessService.connection(in: services, guid: "adb-alpha", host: "192.168.1.8")?.endpoint.port, 37123)
    }

    func testReconnectUsesCurrentPortAndRequiresIdentityForHostFallback() throws {
        let previous = try XCTUnwrap(ADBEndpoint("192.168.1.8:37123"))
        let services = ADBWirelessService.parse("""
        adb-alpha-Z9 _adb-tls-connect._tcp 192.168.1.8:40701
        adb-beta-T1 _adb-tls-connect._tcp 192.168.1.9:40702
        """)
        XCTAssertEqual(ADBWirelessService.reconnectionService(in: services, serial: services[0].serial,
                                                               previous: previous, canVerifyIdentity: false)?.endpoint.port, 40701)
        XCTAssertNil(ADBWirelessService.reconnectionService(in: services, serial: nil,
                                                           previous: previous, canVerifyIdentity: false))
        XCTAssertEqual(ADBWirelessService.reconnectionService(in: services, serial: nil,
                                                               previous: previous, canVerifyIdentity: true)?.endpoint.port, 40701)
        let ambiguous = services + ADBWirelessService.parse("adb-third _adb-tls-connect._tcp 192.168.1.8:40703")
        XCTAssertNil(ADBWirelessService.reconnectionService(in: ambiguous, serial: nil,
                                                           previous: previous, canVerifyIdentity: true))
    }

    func testBonjourSupersedesStaleADBAddressAndKeepsOtherServices() {
        let adb = ADBWirelessService.parse("""
        adb-alpha _adb-tls-connect._tcp 192.168.1.8:37123
        studio-beta _adb-tls-pairing._tcp 192.168.1.9:37201
        """)
        let bonjour = ADBWirelessService.parse("adb-alpha _adb-tls-connect._tcp 192.168.1.8:40701")
        XCTAssertEqual(ADBWirelessService.merging(adb: adb, bonjour: bonjour).map(\.endpoint.port), [40701, 37201])
        XCTAssertEqual(ADBWirelessService.merging(adb: adb, bonjour: []), adb)
    }

    func testPairReadsLeadingZeroCodeFromStdinAndConnectChecksOnlineDevice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-adb")
        let script = #"""
        #!/bin/sh
        cd "$(dirname "$0")" || exit 1
        case "$1" in
          pair)
            [ "$#" -eq 2 ] && [ "$2" = 192.168.1.8:37201 ] || exit 2
            IFS= read -r code
            [ "$code" = 012345 ] || exit 3
            printf 'Successfully paired to %s [guid=adb-alpha]\n' "$2"
            ;;
          connect)
            if [ "$2" = 192.168.1.8:37124 ]; then
              printf "failed to connect to '%s': No route to host\n" "$2"
              exit 0
            fi
            [ "$2" = 192.168.1.8:37123 ] || exit 4
            touch connected
            printf 'already connected\n'
            ;;
          devices)
            printf 'List of devices attached\n192.168.1.8:37123 offline\n'
            if [ -f connected ]; then
              printf 'adb-alpha-Z9._adb-tls-connect._tcp.local device model:Test_Phone\n'
            fi
            ;;
          mdns)
            printf 'adb-alpha-Z9 _adb-tls-connect._tcp 192.168.1.8:37123\n'
            ;;
          *) exit 5 ;;
        esac
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = ADBClient(executable: executable.path)
        let pairEndpoint = try XCTUnwrap(ADBEndpoint("192.168.1.8:37201"))
        let connectEndpoint = try XCTUnwrap(ADBEndpoint("192.168.1.8:37123"))
        let guid = try await client.pairWireless(pairEndpoint, secret: "012345")
        XCTAssertEqual(guid, "adb-alpha")
        do {
            _ = try await client.connectWireless(connectEndpoint, quickAttempt: true)
            XCTFail("The saved-address probe should leave discovery to its caller")
        } catch let failure as ADBWirelessFailure {
            XCTAssertEqual(failure, .notOnline)
        }
        let known = try XCTUnwrap(ADBWirelessService.parse("adb-alpha-Z9 _adb-tls-connect._tcp 192.168.1.8:37123").first)
        let quick = try await client.connectWireless(connectEndpoint, service: known, quickAttempt: true)
        XCTAssertEqual(quick.model, "Test Phone")
        let device = try await client.connectWireless(connectEndpoint)
        XCTAssertEqual(device.model, "Test Phone")
        XCTAssertTrue(device.isWireless)
        let unreachableEndpoint = try XCTUnwrap(ADBEndpoint("192.168.1.8:37124"))
        do {
            _ = try await client.connectWireless(unreachableEndpoint)
            XCTFail("Expected the connection error from ADB output")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("本地网络"))
        }
    }
}
