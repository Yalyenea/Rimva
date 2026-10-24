import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case chinese = "zh-Hans"
    case english = "en"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: L("跟随系统")
        case .chinese: "简体中文"
        case .english: "English"
        }
    }
}

public extension Notification.Name {
    static let rimvaLanguageChanged = Notification.Name("rimvaLanguageChanged")
}

public enum L10n {
    private static let lock = NSLock()
    private static var selectedLanguage: AppLanguage = .system
    // A packaged app keeps resources in Contents/Resources. SwiftPM's command-line
    // executable and tests resolve their adjacent resources through Bundle.module.
    private static let resources = Bundle.main.url(forResource: "Rimva_RimvaCore", withExtension: "bundle")
        .map { Bundle(url: $0)! } ?? Bundle.module
    private static let localizedBundles = ["en", "zh-Hans"].reduce(into: [String: Bundle]()) { bundles, code in
        bundles[code] = Bundle(path: resources.path(forResource: code, ofType: "lproj")!)!
    }

    public static var language: AppLanguage {
        get { lock.withLock { selectedLanguage } }
        set { lock.withLock { selectedLanguage = newValue } }
    }

    private static var languageCode: String {
        switch language {
        case .system: Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-Hans" : "en"
        case .chinese: "zh-Hans"
        case .english: "en"
        }
    }

    public static var locale: Locale { Locale(identifier: languageCode) }

    fileprivate static var bundle: Bundle {
        // Select the resource bundle directly so language changes take effect
        // without restarting the app or changing the user's system settings.
        localizedBundles[languageCode]!
    }
}

public func L(_ key: String, _ arguments: CVarArg...) -> String {
    let format = L10n.bundle.localizedString(forKey: key, value: key, table: nil)
    guard !arguments.isEmpty else { return format }
    return String(format: format, locale: L10n.locale, arguments: arguments)
}
