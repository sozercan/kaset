import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.service))
struct AppLocalizationTests {
    /// Helper to find the specific .lproj bundle and use the legacy API for reliable test verification.
    private func localizedValue(key: String, localeIdentifier: String) -> String {
        let baseBundle = AppLocalization.bundle
        guard let lprojPath = baseBundle.path(forResource: localeIdentifier, ofType: "lproj"),
              let lprojBundle = Bundle(path: lprojPath)
        else {
            return key
        }
        return lprojBundle.localizedString(forKey: key, value: nil, table: nil)
    }

    @Test("Arabic bundle localizes artist strings")
    func arabicLocalizationWorks() {
        let artist = self.localizedValue(key: "Artist", localeIdentifier: "ar")
        #expect(artist == "فنان")
    }

    @Test("Arabic bundle localizes formatted subscribe strings")
    func arabicFormattedLocalizationWorks() {
        let localizedText = self.localizedValue(key: "Subscribe %@", localeIdentifier: "ar")
        let title = String(format: localizedText, locale: Locale(identifier: "ar"), "34.6M")
        #expect(title.hasPrefix("اشترك"))
        #expect(title.contains("34.6M"))
    }

    @Test("Turkish bundle localizes artist strings")
    func turkishLocalizationWorks() {
        let artist = self.localizedValue(key: "Artist", localeIdentifier: "tr")
        #expect(artist == "Sanatçı")
    }

    @Test("Turkish bundle localizes formatted subscribe strings")
    func turkishFormattedLocalizationWorks() {
        let localizedText = self.localizedValue(key: "Subscribe %@", localeIdentifier: "tr")
        let title = String(format: localizedText, locale: Locale(identifier: "tr"), "34.6M")
        #expect(title.hasPrefix("Abone Ol"))
        #expect(title.contains("34.6M"))
    }

    @Test("Korean bundle localizes artist strings")
    func koreanLocalizationWorks() {
        let artist = self.localizedValue(key: "Artist", localeIdentifier: "ko")
        #expect(artist == "아티스트")
    }

    @Test("Override bundle lookup is scoped to Kaset-owned bundles")
    func overrideBundleLookupIsScopedToKasetBundles() {
        AppLocalization.setLanguage("ar")
        defer { AppLocalization.setLanguage(nil) }

        #expect(AppLocalization.shouldOverrideLocalization(for: AppLocalization.baseBundle))
    }

    @Test("Indonesian bundle localizes artist and subscribe strings")
    func indonesianLocalizationWorks() {
        let artist = self.localizedValue(key: "Artist", localeIdentifier: "id")
        let localizedText = self.localizedValue(key: "Subscribe %@", localeIdentifier: "id")
        let title = String(format: localizedText, locale: Locale(identifier: "id"), "34.6M")

        #expect(artist == "Artis")
        #expect(title.hasPrefix("Berlangganan"))
        #expect(title.contains("34.6M"))
    }
}
