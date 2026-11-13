import Foundation

public struct GitHubReleaseSource: Sendable {
    public enum CheckResult: Equatable, Sendable {
        case noPublishedRelease
        case upToDate
        case updateAvailable(version: String, page: URL)
    }

    private enum CheckError: LocalizedError {
        case invalidVersion
        case unexpectedResponse
        case rateLimited

        var errorDescription: String? {
            switch self {
            case .invalidVersion: return L10n.text("应用版本或 GitHub 发布标签格式无效。")
            case .unexpectedResponse: return L10n.text("GitHub 暂时无法返回发布信息，请稍后重试。")
            case .rateLimited: return L10n.text("GitHub 暂时限制了查询次数，请稍后重试。")
            }
        }
    }

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
    }

    private let repository: String

    public init?(repository: String) {
        guard repository.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*/#) != nil else { return nil }
        self.repository = repository
    }

    public func check(currentVersion: String) async throws -> CheckResult {
        let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CheckError.unexpectedResponse }
        if http.statusCode == 403, http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
            throw CheckError.rateLimited
        }
        return try result(data: data, status: http.statusCode, currentVersion: currentVersion)
    }

    func result(data: Data, status: Int, currentVersion: String) throws -> CheckResult {
        switch status {
        case 404: return .noPublishedRelease
        case 429: throw CheckError.rateLimited
        case 200: break
        default: throw CheckError.unexpectedResponse
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease else { return .noPublishedRelease }
        guard let current = Self.versionParts(currentVersion), let latest = Self.versionParts(release.tag_name) else {
            throw CheckError.invalidVersion
        }
        guard current.lexicographicallyPrecedes(latest) else { return .upToDate }
        let page = URL(string: "https://github.com/\(repository)/releases/tag/\(release.tag_name)")!
        return .updateAvailable(version: latest.map(String.init).joined(separator: "."), page: page)
    }

    private static func versionParts(_ tag: String) -> [Int]? {
        let version = tag.hasPrefix("v") ? tag.dropFirst() : tag[...]
        let fields = version.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        let numbers = fields.compactMap { part -> Int? in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int(part)
        }
        return numbers.count == 3 ? numbers : nil
    }
}
