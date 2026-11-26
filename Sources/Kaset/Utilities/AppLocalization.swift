import Foundation
import SwiftUI

enum AppLocalization {
    static let baseBundle = PackageResourceLookup.localizationBundle ?? Bundle.main

    // swiftformat:disable modifierOrder
    nonisolated(unsafe) static var overrideBundle: Bundle?
    nonisolated(unsafe) static var overrideLanguageCode: String?
    // swiftformat:enable modifierOrder

    static var bundle: Bundle {
        self.overrideBundle ?? self.baseBundle
    }

    private static let appBundleURLs: Set<URL> = [
        Self.baseBundle.bundleURL.resolvingSymlinksInPath().standardizedFileURL,
        Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL,
    ]

    static func setLanguage(_ languageCode: String?) {
        self.overrideLanguageCode = languageCode

        guard let code = languageCode else {
            self.overrideBundle = nil
            return
        }

        self.overrideBundle = Self.bundle(forLocalization: code)
    }

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

private struct LocalizedNavigationTitleModifier: ViewModifier {
    let key: String
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        let _ = self.locale // swiftlint:disable:this redundant_discardable_let
        content.navigationTitle(AppLocalization.localizedString(forKey: self.key, value: nil, table: nil))
    }
}

extension View {
    func localizedNavigationTitle(_ key: String) -> some View {
        self.modifier(LocalizedNavigationTitleModifier(key: key))
    }
}

extension Bundle {
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
