import Foundation
import SwiftUI

// MARK: - AppLocalization

enum AppLocalization {
    /// The base resource bundle discovered at launch.
    static let baseBundle = PackageResourceLookup.localizationBundle ?? Bundle.main

    // swiftformat:disable modifierOrder
    /// Override bundle for a specific language, set via `setLanguage(_:)`.
    nonisolated(unsafe) static var overrideBundle: Bundle?
    /// The selected language code, including development-region overrides.
    nonisolated(unsafe) static var overrideLanguageCode: String?
    // swiftformat:enable modifierOrder

    /// The active localization bundle.
    static var bundle: Bundle {
        self.overrideBundle ?? self.baseBundle
    }

    private static let appBundleURLs: Set<URL> = [
        Self.baseBundle.bundleURL.resolvingSymlinksInPath().standardizedFileURL,
        Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL,
    ]

    /// Sets the active language by loading the corresponding `.lproj` bundle.
    /// Pass `nil` to revert to the system default.
    static func setLanguage(_ languageCode: String?) {
        self.overrideLanguageCode = languageCode

        guard let code = languageCode else {
            self.overrideBundle = nil
            return
        }

        self.overrideBundle = Self.bundle(forLocalization: code)
    }

    /// Finds a bundle for a specific localization, including development-region
    /// localizations that may be emitted from `.xcstrings` resources.
    static func bundle(forLocalization localization: String) -> Bundle? {
        if let bundlePath = self.baseBundle.path(forResource: localization, ofType: "lproj"),
           let bundle = Bundle(path: bundlePath)
        {
            return bundle
        }

        guard let stringsPath = self.baseBundle.path(
            forResource: "Localizable",
            ofType: "strings",
            inDirectory: nil,
            forLocalization: localization
        ) else {
            return nil
        }

        let localizationDirectory = URL(fileURLWithPath: stringsPath).deletingLastPathComponent()
        return Bundle(url: localizationDirectory)
    }

    /// Resolves an app-localized string while honoring development-region
    /// overrides that may not emit a physical `.lproj` bundle in SwiftPM builds.
    static func localizedString(forKey key: String, value: String? = nil, table: String? = nil) -> String {
        if self.overrideBundle == nil,
           self.overrideLanguageCode == self.baseBundle.developmentLocalization
        {
            return value ?? key
        }

        return self.bundle.localizedString(forKey: key, value: value, table: table)
    }

    static func shouldOverrideLocalization(for bundle: Bundle) -> Bool {
        self.appBundleURLs.contains(bundle.bundleURL.resolvingSymlinksInPath().standardizedFileURL)
    }

    static func lookupBundle(for bundle: Bundle) -> Bundle {
        guard let overrideBundle = self.overrideBundle,
              self.shouldOverrideLocalization(for: bundle)
        else {
            return bundle
        }

        return overrideBundle
    }
}

extension String {
    init(localized key: LocalizationValue) {
        self = String(localized: key, bundle: AppLocalization.bundle)
    }
}

// MARK: - LocalizedNavigationTitleModifier

/// Re-evaluates the navigation title when the app language changes.
/// Uses `Bundle.localizedString(forKey:value:table:)` because `AppLocalization.bundle`
/// may be a resolved `.lproj` sub-bundle, and this method reads strings from it directly.
@available(macOS 26.0, *)
private struct LocalizedNavigationTitleModifier: ViewModifier {
    let key: String
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        let _ = self.locale // swiftlint:disable:this redundant_discardable_let
        content.navigationTitle(AppLocalization.localizedString(forKey: self.key, value: nil, table: nil))
    }
}

@available(macOS 26.0, *)
extension View {
    func localizedNavigationTitle(_ key: String) -> some View {
        self.modifier(LocalizedNavigationTitleModifier(key: key))
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
        let bundle = AppLocalization.lookupBundle(for: self)
        return bundle._appOverrideLocalizedString(forKey: key, value: value, table: tableName)
    }
}
