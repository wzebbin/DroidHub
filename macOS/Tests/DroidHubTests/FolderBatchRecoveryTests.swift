import DroidHubCore
import Foundation
import XCTest

final class FolderBatchRecoveryTests: XCTestCase {
    private actor Progress {
        var firstCompleted: Int?
        var lastCompleted = 0

        func record(_ progress: TransferProgress) {
            guard case let .folder(folder, _, _) = progress else { return }
            if firstCompleted == nil { firstCompleted = folder.completedFiles }
            lastCompleted = folder.completedFiles
        }
    }

    func testInterruptedSmallFileBatchesResumeOnPhone() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let adb = env["DROIDHUB_BATCH_QA_ADB"], let serial = env["DROIDHUB_BATCH_QA_SERIAL"],
              let remote = env["DROIDHUB_BATCH_QA_ROOT"] else { throw XCTSkip("No explicit folder batch fixture") }
        let manager = FileManager.default
        let local = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = local.appendingPathComponent("source")
        try manager.createDirectory(at: source.appendingPathComponent("empty/nested"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: local) }
        for index in 0..<96 {
            let file = source.appendingPathComponent(String(format: "%03d.txt", index))
            try Data(String(index).utf8).write(to: file)
        }
        _ = try await ProcessRunner.run(adb, ["-s", serial, "shell", "mkdir", "-p", remote])
        let real = ADBClient(executable: adb)
        let devices = try await real.devices()
        let wireless = try XCTUnwrap(devices.first { $0.serial == serial }).isWireless

        for upload in [true, false] {
            let tool = local.appendingPathComponent(upload ? "adb-upload" : "adb-download")
            try makeInterruptingADB(at: tool, using: adb, upload: upload)
            let client = ADBClient(executable: tool.path)
            let checkpoint = UUID()
            let destination = local.appendingPathComponent("download")
            let initial = Progress()
            let previous = try await real.devices().first { $0.serial == serial }?.transportID
            do {
                if upload {
                    try await client.uploadFolder(serial: serial, local: source, directory: remote, checkpointID: checkpoint,
                                                  progress: { await initial.record($0) })
                } else {
                    try await client.downloadFolder(serial: serial, remote: remote + "/source", destination: destination,
                                                    checkpointID: checkpoint, progress: { await initial.record($0) })
                }
                XCTFail("The transfer finished without exercising the interruption")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("batch interrupted"), error.localizedDescription)
            }
            if wireless { _ = try await ProcessRunner.run(adb, ["connect", serial]) }
            var reconnected = false
            for _ in 0..<80 {
                let devices = try await real.devices()
                if devices.contains(where: { $0.serial == serial && $0.isOnline && $0.transportID != previous }) {
                    reconnected = true
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(reconnected)
            let retry = Progress()
            if upload {
                try await client.uploadFolder(serial: serial, local: source, directory: remote, checkpointID: checkpoint,
                                              automatic: true, progress: { await retry.record($0) })
            } else {
                try await client.downloadFolder(serial: serial, remote: remote + "/source", destination: destination,
                                                checkpointID: checkpoint, automatic: true, progress: { await retry.record($0) })
            }
            let kept = await retry.firstCompleted
            let original = await initial.lastCompleted
            XCTAssertEqual(kept, upload ? 4 : original)
            if !upload { XCTAssertGreaterThan(original, 0) }
            let finished = await retry.lastCompleted
            XCTAssertEqual(finished, 96)
            print("Verified \(wireless ? "Wi-Fi" : "USB") small-file \(upload ? "upload" : "download") resumed with \(kept ?? 0) files")
        }

        XCTAssertEqual(Set(try XCTUnwrap(manager.subpaths(atPath: source.path))),
                       Set(try XCTUnwrap(manager.subpaths(atPath: local.appendingPathComponent("download").path))))
        for index in 0..<96 {
            let path = String(format: "%03d.txt", index)
            XCTAssertTrue(manager.contentsEqual(atPath: source.appendingPathComponent(path).path,
                                                andPath: local.appendingPathComponent("download/" + path).path))
        }
    }

    private func makeInterruptingADB(at file: URL, using adb: String, upload: Bool) throws {
        let script = #"""
        #!/usr/bin/python3
        import pathlib, shlex, subprocess, sys
        adb = \#(String(reflecting: adb))
        upload = \#(upload ? "True" : "False")
        args = sys.argv[1:]
        marker = pathlib.Path(__file__ + ".marker")
        partial = None
        if upload and len(args) == 7 and args[2:6] == ["shell", "-T", "sh", "-c"]:
            lines = shlex.split(args[6])[0].splitlines()
            points = [i for i, line in enumerate(lines) if line.startswith('commit "$batch/')]
            if len(points) >= 4 and not marker.exists():
                marker.touch()
                partial = [*args[:6], shlex.quote("\n".join(lines[:points[3] + 1]))]
        elif not upload and len(args) >= 8 and args[2] == "pull":
            seen = int(marker.read_text()) if marker.exists() else 0
            marker.write_text(str(seen + 1))
            if seen == 1:
                partial = [*args[:7], args[-1]]
        if partial is not None:
            subprocess.run([adb, *partial], check=True)
            subprocess.run([adb, "-s", args[1], "reconnect"], stdout=sys.stderr, check=True)
            sys.stderr.write("batch interrupted\n")
            sys.exit(1)
        import os
        os.execv(adb, [adb, *args])
        """#
        try Data(script.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }
}
