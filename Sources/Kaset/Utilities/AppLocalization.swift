import Foundation

// MARK: - AppLocalization

enum AppLocalization {
    /// The base resource bundle discovered at launch.
    static let baseBundle = PackageResourceLookup.localizationBundle ?? Bundle.main

    // swiftformat:disable modifierOrder
    /// Override bundle for a specific language, set via `setLanguage(_:)`.
    nonisolated(unsafe) static var overrideBundle: Bundle?
    // swiftformat:enable modifierOrder

    /// The active localization bundle.
    static var bundle: Bundle {
        self.overrideBundle ?? self.baseBundle
    }

    /// Sets the active language by loading the corresponding `.lproj` bundle.
    /// Pass `nil` to revert to the system default.
    static func setLanguage(_ languageCode: String?) {
        guard let code = languageCode else {
            self.overrideBundle = nil
            return
        }
        if let path = self.baseBundle.path(forResource: code, ofType: "lproj"),
           let lprojBundle = Bundle(path: path)
        {
            self.overrideBundle = lprojBundle
        } else {
            self.overrideBundle = nil
        }
    }
}

extension String {
    init(localized key: LocalizationValue) {
        self = String(localized: key, bundle: AppLocalization.bundle)
    }
}

// MARK: - Bundle Localization Override

extension Bundle {
    /// Redirects SwiftUI views (`Text`, `Button`, `Label`, etc.) to use
    /// `AppLocalization.overrideBundle` when a language override is active.
    static func enableAppLocalizationOverride() {
        let original = #selector(localizedString(forKey:value:table:))
        let swizzled = #selector(_appOverrideLocalizedString(forKey:value:table:))

        guard let originalMethod = class_getInstanceMethod(Bundle.self, original),
              let swizzledMethod = class_getInstanceMethod(Bundle.self, swizzled)
        else { return }

        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    @objc private func _appOverrideLocalizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        let bundle = AppLocalization.overrideBundle ?? self
        return bundle._appOverrideLocalizedString(forKey: key, value: value, table: tableName)
    }
}
