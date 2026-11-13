import DroidHubCore
import SwiftUI

private struct AppLanguageKey: EnvironmentKey {
    static var defaultValue: AppLanguage { AppLanguage.current }
}

extension EnvironmentValues {
    fileprivate var appLanguage: AppLanguage {
        get { self[AppLanguageKey.self] }
        set { self[AppLanguageKey.self] = newValue }
    }

    var l10n: L10n { L10n(appLanguage) }
}

extension View {
    func appLanguage(_ language: AppLanguage) -> some View {
        environment(\.appLanguage, language)
            .environment(\.locale, Locale(identifier: language.rawValue))
    }
}
