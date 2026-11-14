import Foundation

public struct GitHubReleaseSource: Sendable {
    public enum CheckResult: Equatable, Sendable {
        case noPublishedRelease
        case upToDate
        case updateAvailable(version: String, page: URL, isPreview: Bool)
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

    struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
    }

    private let repository: String

    public init?(repository: String) {
        guard repository.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*/#) != nil else { return nil }
        self.repository = repository
    }

    public var projectURL: URL { URL(string: "https://github.com/\(repository)")! }

    public func check(currentVersion: String, includePreviews: Bool = false) async throws -> CheckResult {
        let endpoint = "https://api.github.com/repos/\(repository)/releases"
        if !includePreviews {
            let (data, response) = try await fetch(URL(string: endpoint + "/latest")!)
            return try result(data: data, status: response.statusCode, currentVersion: currentVersion)
        }

        var releases: [Release] = []
        var page = 1
        while true {
            let (data, response) = try await fetch(URL(string: endpoint + "?per_page=100&page=\(page)")!)
            if page == 1 && response.statusCode == 404 { return .noPublishedRelease }
            guard response.statusCode == 200 else { throw CheckError.unexpectedResponse }
            releases += try JSONDecoder().decode([Release].self, from: data)
            let links = response.value(forHTTPHeaderField: "Link") ?? ""
            guard links.contains("rel=\"next\"") else { break }
            page += 1
        }
        return try bestResult(from: releases, currentVersion: currentVersion)
    }

    private func fetch(_ endpoint: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CheckError.unexpectedResponse }
        if http.statusCode == 429 || (http.statusCode == 403 && http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0") {
            throw CheckError.rateLimited
        }
        return (data, http)
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
        guard let version = Self.versionParts(release.tag_name) else { throw CheckError.invalidVersion }
        return try updateResult(for: release, version: version, currentVersion: currentVersion)
    }

    func bestResult(from releases: [Release], currentVersion: String) throws -> CheckResult {
        let candidates = releases.filter { !$0.draft }.compactMap { release in
            Self.versionParts(release.tag_name).map { (release: release, version: $0) }
        }
        guard let best = candidates.max(by: { left, right in
            if left.version == right.version { return left.release.prerelease && !right.release.prerelease }
            return left.version.lexicographicallyPrecedes(right.version)
        }) else { return .noPublishedRelease }
        return try updateResult(for: best.release, version: best.version, currentVersion: currentVersion)
    }

    private func updateResult(for release: Release, version: [Int], currentVersion: String) throws -> CheckResult {
        guard let current = Self.versionParts(currentVersion) else {
            throw CheckError.invalidVersion
        }
        guard current.lexicographicallyPrecedes(version) else { return .upToDate }
        let page = projectURL.appendingPathComponent("releases").appendingPathComponent("tag")
            .appendingPathComponent(release.tag_name)
        return .updateAvailable(version: version.map(String.init).joined(separator: "."), page: page,
                                isPreview: release.prerelease)
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
