import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public static let preferenceKey = "appLanguage"

    public static var current: Self {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .simplifiedChinese
    }

    public var name: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }
}

public struct L10n: Sendable {
    public let language: AppLanguage

    public init(_ language: AppLanguage) {
        self.language = language
    }

    private static let english = Bundle.module.path(forResource: "en", ofType: "lproj")
        .flatMap(Bundle.init(path:))
    private static let placeholders = try! NSRegularExpression(pattern: #"\{([1-9][0-9]*)\}"#)

    public static func text(_ key: String, _ arguments: Any...) -> String {
        Self(AppLanguage.current).render(key, arguments)
    }

    public func text(_ key: String, _ arguments: Any...) -> String {
        render(key, arguments)
    }

    private func render(_ key: String, _ arguments: [Any]) -> String {
        let template = language == .english
            ? Self.english?.localizedString(forKey: key, value: key, table: nil) ?? key
            : key
        guard !arguments.isEmpty else { return template }
        var result = ""
        var cursor = template.startIndex
        let range = NSRange(template.startIndex..., in: template)
        for match in Self.placeholders.matches(in: template, range: range) {
            guard let number = Range(match.range(at: 1), in: template),
                  let index = Int(template[number]), arguments.indices.contains(index - 1),
                  let span = Range(match.range, in: template) else { continue }
            result += template[cursor..<span.lowerBound]
            result += String(describing: arguments[index - 1])
            cursor = span.upperBound
        }
        result += template[cursor...]
        return result
    }

    public static func diagnostic(_ message: String) -> String {
        Self(AppLanguage.current).diagnostic(message)
    }

    public func diagnostic(_ message: String) -> String {
        message.split(separator: "\n", omittingEmptySubsequences: false)
            .map { text(String($0)) }.joined(separator: "\n")
    }
}
