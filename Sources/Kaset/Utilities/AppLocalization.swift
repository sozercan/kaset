import Foundation

// MARK: - AppLocalization

enum AppLocalization {
    /// SwiftPM's generated `Bundle.module` accessor for this executable target
    /// crashes when the resource bundle is embedded inside a packaged `.app`.
    /// Resolve the copied SwiftPM bundle manually and fall back to `Bundle.main`
    /// when localizations were compiled directly into the app resources.
    static let bundle = PackageResourceLookup.localizationBundle ?? Bundle.main

    static func string(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: self.bundle)
    }
}

extension String {
    init(localized key: LocalizationValue) {
        self = AppLocalization.string(key)
    }
}
