import Foundation
import Darwin

private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    enum StopReason {
        case cancelled, timedOut, interrupted

        var error: Error {
            switch self {
            case .cancelled, .interrupted: return CancellationError()
            case .timedOut: return HubError.message("命令执行超时。请检查连接后重试。")
            }
        }
    }

    private var stopReason: StopReason?

    func launch(_ value: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if let stopReason { throw stopReason.error }
        try value.run()
        process = value
    }

    func stop(_ reason: StopReason) {
        lock.lock(); defer { lock.unlock() }
        guard stopReason == nil else { return }
        if let process, !process.isRunning { return }
        stopReason = reason
        guard let process else { return }
        if reason == .interrupted { process.interrupt() }
        else { process.terminate() }
        let gracePeriod: DispatchTimeInterval = reason == .interrupted ? .seconds(10) : .milliseconds(500)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + gracePeriod) { [weak self] in
            self?.forceStop()
        }
    }

    private func forceStop() {
        lock.lock(); defer { lock.unlock() }
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    func finish() throws {
        lock.lock(); defer { lock.unlock() }
        process = nil
        if let stopReason, stopReason != .interrupted { throw stopReason.error }
    }
}

public enum ProcessRunner {
    public final class Interruption: Sendable {
        fileprivate let control = ProcessControl()

        public init() {}

        public func interrupt() { control.stop(.interrupted) }
    }

    // Unlinked files retain the deadlock protection of file-backed output and
    // are reclaimed even if the app exits before cleanup.
    private static func temporaryOutput() throws -> FileHandle {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("droidhub-process.XXXXXX").path
        var template = Array(path.utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard unlink(template) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) != -1 else {
            let failure = errno
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30,
                           input: Data? = nil, environmentOverrides: [String: String] = [:],
                           output: FileHandle? = nil, inputFile: FileHandle? = nil,
                           interruption: Interruption? = nil,
                           onLaunch: (@Sendable (Int32) -> Void)? = nil) async throws -> Data {
        let control = interruption?.control ?? ProcessControl()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let stdout = try output ?? temporaryOutput()
                        defer { if output == nil { try? stdout.close() } }
                        let stderr = try temporaryOutput()
                        defer { try? stderr.close() }
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: executable)
                        process.arguments = arguments
                        process.standardOutput = stdout
                        process.standardError = stderr
                        process.standardInput = inputFile ?? FileHandle.nullDevice
                        if let input {
                            guard input.count <= 512 else { throw HubError.message("命令输入过长。") }
                            let pipe = Pipe()
                            try pipe.fileHandleForWriting.write(contentsOf: input)
                            try pipe.fileHandleForWriting.close()
                            process.standardInput = pipe.fileHandleForReading
                        }
                        var environment = ProcessInfo.processInfo.environment
                        environment["PATH"] = URL(fileURLWithPath: executable).deletingLastPathComponent().path
                            + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                        environment.merge(environmentOverrides) { _, override in override }
                        process.environment = environment
                        try control.launch(process)
                        onLaunch?(process.processIdentifier)
                        let deadline = DispatchWorkItem { control.stop(.timedOut) }
                        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                        process.waitUntilExit()
                        deadline.cancel()
                        try control.finish()
                        guard process.terminationStatus == 0 else {
                            let end = try stderr.seekToEnd()
                            try stderr.seek(toOffset: end > 8_000 ? end - 8_000 : 0)
                            let message = String(decoding: try stderr.readToEnd() ?? Data(), as: UTF8.self)
                            throw HubError.message(message.isEmpty ? "操作中断、超时或执行失败。" : String(message.suffix(2000)))
                        }
                        if output == nil {
                            try stdout.seek(toOffset: 0)
                            continuation.resume(returning: try stdout.readToEnd() ?? Data())
                        } else {
                            continuation.resume(returning: Data())
                        }
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { control.stop(.cancelled) })
    }

    static func deviceEvents(_ executable: String) -> AsyncThrowingStream<Void, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let process = Process()
            let pipe = Pipe()
            let control = ProcessControl()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["track-devices", "-l"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            pipe.fileHandleForReading.readabilityHandler = { handle in
                if handle.availableData.isEmpty { handle.readabilityHandler = nil }
                else { continuation.yield(()) }
            }
            process.terminationHandler = { finished in
                finished.terminationHandler = nil
                continuation.finish()
            }
            continuation.onTermination = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                control.stop(.cancelled)
            }
            do { try control.launch(process) }
            catch { continuation.finish(throwing: error) }
        }
    }
}
