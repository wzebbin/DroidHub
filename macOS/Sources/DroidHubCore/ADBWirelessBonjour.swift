import Foundation
import Darwin

@MainActor
// The browser and resolver deliver delegate calls on the run loop that starts them.
final class ADBWirelessBonjour: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private let browsers = [NetServiceBrowser(), NetServiceBrowser()]
    private var services: [NetService: ADBWirelessService.Kind] = [:]
    private var resolved: [NetService: ADBWirelessService] = [:]
    private var continuation: CheckedContinuation<[ADBWirelessService], Never>?

    func discover() async -> [ADBWirelessService] {
        let deadline = Task {
            try await Task.sleep(nanoseconds: 1_200_000_000)
            finish()
        }
        defer { deadline.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                for (browser, kind) in zip(browsers, [ADBWirelessService.Kind.connection, .pairing]) {
                    browser.delegate = self
                    browser.searchForServices(ofType: kind.rawValue + ".", inDomain: "local.")
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish() }
        }
    }

    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        for browser in browsers {
            browser.delegate = nil
            browser.stop()
        }
        for service in services.keys {
            service.delegate = nil
            service.stop()
        }
        continuation.resume(returning: Array(Set(resolved.values)).sorted { $0.id < $1.id })
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard let kind = ADBWirelessService.Kind(rawValue: service.type.trimmingCharacters(in: CharacterSet(charactersIn: "."))),
              services[service] == nil else { return }
        services[service] = kind
        service.delegate = self
        service.resolve(withTimeout: 1.2)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard let active = services.keys.first(where: { $0 == service }) else { return }
        active.delegate = nil
        active.stop()
        services.removeValue(forKey: active)
        resolved.removeValue(forKey: active)
    }

    func netServiceDidResolveAddress(_ service: NetService) {
        guard let kind = services[service] else { return }
        let endpoints = (service.addresses ?? []).compactMap { address in
            address.withUnsafeBytes { buffer -> ADBEndpoint? in
                guard buffer.count >= MemoryLayout<sockaddr>.size,
                      let socketAddress = buffer.bindMemory(to: sockaddr.self).baseAddress else { return nil }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(socketAddress, socklen_t(buffer.count), &host, socklen_t(host.count),
                                         nil, 0, NI_NUMERICHOST)
                guard result == 0 else { return nil }
                return ADBEndpoint(host: String(cString: host), port: String(service.port))
            }
        }
        guard let endpoint = endpoints.first(where: { !$0.host.contains(":") }) ?? endpoints.first else { return }
        resolved[service] = ADBWirelessService(name: service.name, kind: kind, endpoint: endpoint)
    }
}
