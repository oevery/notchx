import Foundation
import SwiftUI

/// One preference shared by SwiftUI and AppKit. No global locale mutation.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", simplifiedChinese = "zh-Hans"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L10n.text("Follow System")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }
}

enum L10n {
    static let preferenceKey = "notchx.language"
    static var language: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "system") ?? .system
    }
    static var languageCode: String {
        if language != .system { return language.rawValue }
        return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-Hans" : "en"
    }
    static var locale: Locale { Locale(identifier: languageCode) }
    static var bundle: Bundle {
        guard let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
              let localized = Bundle(path: path) else { return .main }
        return localized
    }
    /// Use for dynamic UI labels and AppKit menus/alerts; pass stable English keys.
    static func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }
}

private struct NotchXLocalization: ViewModifier {
    @AppStorage(L10n.preferenceKey) private var language = AppLanguage.system.rawValue
    func body(content: Content) -> some View {
        content.environment(\.locale, L10n.locale)
            .id(language)
    }
}

extension View {
    /// Apply at each NSHostingController or scene root, keeping language live.
    func notchXLocalized() -> some View { modifier(NotchXLocalization()) }
}

struct LanguagePicker: View {
    @AppStorage(L10n.preferenceKey) private var language = AppLanguage.system.rawValue
    var body: some View {
        Picker(L10n.text("Language"), selection: $language) {
            ForEach(AppLanguage.allCases) { language in
                Text(language.title).tag(language.rawValue)
            }
        }
    }
}
