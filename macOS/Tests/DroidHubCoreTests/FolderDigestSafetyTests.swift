import Darwin
import DroidHubCore
import Foundation
import XCTest

final class FolderDigestSafetyTests: XCTestCase {
    private actor EditResult {
        var didEdit = false
        var error: Error?

        func edit(_ operation: () async throws -> Void) async {
            do {
                try await operation()
                didEdit = true
            } catch { self.error = error }
        }
    }

    func testSameSizeChangesToReusedFilesPreventCommit() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let adb = env["DROIDHUB_DIGEST_QA_ADB"], let serial = env["DROIDHUB_DIGEST_QA_SERIAL"],
              let remote = env["DROIDHUB_DIGEST_QA_ROOT"] else { throw XCTSkip("No folder digest fixture") }
        let client = ADBClient(executable: adb)
        let manager = FileManager.default
        let temp = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: temp) }
        let bytes = Data(repeating: 42, count: 4 * 1024 * 1024)
        let filename = "retained.bin"
        let seed = temp.appendingPathComponent(filename)
        try bytes.write(to: seed)

        @Sendable func phone(_ script: String) async throws {
            _ = try await ProcessRunner.run(adb, ["-s", serial, "shell", "-T", "sh", "-c", Shell.quote(script)])
        }
        @Sendable func editPhone(_ path: String) async throws {
            let name = Shell.quote(path)
            try await phone("""
            set -e
            before=$(stat -c '%s|%y' -- \(name))
            printf X | dd of=\(name) bs=1 count=1 conv=notrunc 2>/dev/null
            touch -t 202001010000 \(name)
            test "$(stat -c '%s|%y' -- \(name))" = "$before"
            """)
        }

        for upload in [true, false] {
            for changeStage in [true, false] {
                let label = (upload ? "upload" : "download") + (changeStage ? "-stage" : "-source")
                let parent = remote + "/" + label
                let id = UUID()
                let localRoot = temp.appendingPathComponent(label)
                try manager.createDirectory(at: localRoot, withIntermediateDirectories: false)
                let source = localRoot.appendingPathComponent("source")
                let destination = localRoot.appendingPathComponent("result")
                let localStage = localRoot.appendingPathComponent(".droidhub-folder-\(id.uuidString).part/tree")
                let phoneStage = ADBClient.uploadFolderStagingPath(directory: parent, id: id) + "/tree"
                let phoneSource = parent + "/source"
                let localFolder = upload ? source : localStage
                let phoneFolder = upload ? phoneStage : phoneSource
                try manager.createDirectory(at: localFolder, withIntermediateDirectories: true)
                try bytes.write(to: localFolder.appendingPathComponent(filename))
                try await phone("mkdir -p -- \(Shell.quote(phoneFolder))")
                _ = try await ProcessRunner.run(adb, ["-s", serial, "push", seed.path, phoneFolder + "/" + filename])
                try await phone("touch -t 202001010000 \(Shell.quote(phoneFolder + "/" + filename))")

                let edits = EditResult()
                let progress: @Sendable (TransferProgress) async -> Void = { update in
                    guard case .verifying = update else { return }
                    await edits.edit {
                        if upload == changeStage {
                            try await editPhone(phoneFolder + "/" + filename)
                        } else {
                            try Self.editLocal(localFolder.appendingPathComponent(filename))
                        }
                    }
                }
                do {
                    if upload {
                        try await client.uploadFolder(serial: serial, local: source, directory: parent, checkpointID: id,
                                                      automatic: true, progress: progress)
                    } else {
                        try await client.downloadFolder(serial: serial, remote: phoneSource, destination: destination,
                                                        checkpointID: id, automatic: true, progress: progress)
                    }
                    XCTFail("Changed file committed in \(label)")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains("SHA-256"), "\(label): \(error.localizedDescription)")
                }
                let editError = await edits.error
                XCTAssertNil(editError)
                let didEdit = await edits.didEdit
                XCTAssertTrue(didEdit)
                if upload {
                    try await phone("test ! -e \(Shell.quote(parent + "/source"))")
                } else {
                    XCTAssertFalse(manager.fileExists(atPath: destination.path))
                }
                print("Verified digest tampering \(label)")
            }
        }
    }

    private static func editLocal(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(handle.fileDescriptor, &before) == 0 else { throw POSIXError(.EIO) }
        try handle.write(contentsOf: Data([88]))
        var times = [before.st_atimespec, before.st_mtimespec]
        guard times.withUnsafeMutableBufferPointer({ futimens(handle.fileDescriptor, $0.baseAddress) }) == 0 else {
            throw POSIXError(.EIO)
        }
        var after = stat()
        guard fstat(handle.fileDescriptor, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw POSIXError(.EIO) }
    }
}
