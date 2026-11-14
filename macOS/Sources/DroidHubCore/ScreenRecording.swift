import AVFoundation
import Foundation

public enum ScreenRecording {
    public static func save(executable: String, serial: String, directory: URL,
                            environment: [String: String], interruption: ProcessRunner.Interruption,
                            onStarted: @escaping @MainActor @Sendable (ContinuousClock.Instant) -> Void,
                            onSaving: @MainActor @Sendable () -> Void) async throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let staging = directory.appendingPathComponent(".recording-\(id).mp4")
        defer { try? manager.removeItem(at: staging) }

        let arguments = ["--serial", serial, "--no-playback", "--no-window", "--no-control", "--no-audio",
                         "--max-size", "1920", "--max-fps", "30", "--record", staging.path]
        // scrcpy opens this unique output when its recorder starts, after launching the client.
        let readiness = Task {
            while !Task.isCancelled {
                if FileManager.default.fileExists(atPath: staging.path) {
                    await onStarted(ContinuousClock.now)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
        }
        var processError: Error?
        do {
            _ = try await ProcessRunner.run(executable, arguments, timeout: 86400,
                                            environmentOverrides: environment, interruption: interruption)
        } catch {
            processError = error
        }
        readiness.cancel()
        await readiness.value
        await onSaving()

        // scrcpy may report a disconnect after writing a playable recording.
        let asset = AVURLAsset(url: staging)
        let track = try? await asset.loadTracks(withMediaType: .video).first
        let duration = try? await asset.load(.duration).seconds
        guard track != nil, let duration, duration.isFinite, duration > 0 else {
            throw processError ?? HubError.message(L10n.text("手机没有返回可播放的录屏。"))
        }

        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd HHmmss"
        let destination = directory.appendingPathComponent(L10n.text("手机录屏 {1}-{2}.mp4", date.string(from: .now), id.prefix(8)))
        try manager.moveItem(at: staging, to: destination)
        return destination
    }
}
