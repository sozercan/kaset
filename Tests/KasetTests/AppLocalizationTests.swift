import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.service))
struct AppLocalizationTests {
    /// Helper to find the specific `.lproj` bundle for direct string verification.
    private func localizedBundle(for localization: String) -> Bundle? {
        AppLocalization.bundle(forLocalization: localization)
    }

    /// Helper to read a localized string from a specific locale bundle.
    private func localizedValue(key: String, localeIdentifier: String) -> String {
        guard let lprojBundle = self.localizedBundle(for: localeIdentifier) else {
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

    @Test("Korean bundle localizes artist and subscribe strings")
    func koreanLocalizationWorks() {
        let artist = self.localizedValue(key: "Artist", localeIdentifier: "ko")
        let localizedText = self.localizedValue(key: "Subscribe %@", localeIdentifier: "ko")
        let title = String(format: localizedText, locale: Locale(identifier: "ko"), "34.6M")

        #expect(artist == "아티스트")
        #expect(title.hasPrefix("구독"))
        #expect(title.contains("34.6M"))
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

    @Test("French bundle localizes artist and subscribe strings")
    func frenchLocalizationWorks() throws {
        let frenchBundle = try #require(self.localizedBundle(for: "fr"))
        let format = frenchBundle.localizedString(forKey: "Subscribe %@", value: nil, table: nil)
        let title = String(format: format, locale: Locale(identifier: "fr"), "34.6M")
        let romanizeLabel = frenchBundle.localizedString(forKey: "Romanize Lyrics", value: nil, table: nil)
        let romanizeHelp = frenchBundle.localizedString(
            forKey: "Show romanized text (romaji, pinyin, etc.) below non-Latin lyrics",
            value: nil,
            table: nil
        )

        #expect(frenchBundle.localizedString(forKey: "Artist", value: nil, table: nil) == "Artiste")
        #expect(title.hasPrefix("S'abonner"))
        #expect(title.contains("34.6M"))
        #expect(romanizeLabel == "Romaniser les paroles")
        #expect(romanizeHelp == "Afficher le texte romanisé (romaji, pinyin, etc.) sous les paroles non latines")
    }

    @Test("Override bundle lookup is scoped to Kaset-owned bundles")
    func overrideBundleLookupIsScopedToKasetBundles() throws {
        AppLocalization.setLanguage("ar")
        defer { AppLocalization.setLanguage(nil) }

        let overrideBundle = try #require(AppLocalization.overrideBundle)
        let frameworkBundle = try #require(
            Bundle.allFrameworks.first { bundle in
                bundle.bundleURL.resolvingSymlinksInPath().standardizedFileURL !=
                    AppLocalization.baseBundle.bundleURL.resolvingSymlinksInPath().standardizedFileURL
                    && bundle.bundleURL.resolvingSymlinksInPath().standardizedFileURL !=
                    Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
            }
        )

        #expect(AppLocalization.shouldOverrideLocalization(for: AppLocalization.baseBundle))
        #expect(AppLocalization.lookupBundle(for: AppLocalization.baseBundle).bundleURL == overrideBundle.bundleURL)
        #expect(AppLocalization.shouldOverrideLocalization(for: frameworkBundle) == false)
        #expect(AppLocalization.lookupBundle(for: frameworkBundle).bundleURL == frameworkBundle.bundleURL)
    }

    @Test("Navigation title keys resolve correctly from lproj sub-bundles")
    func lprojBundleResolvesNavigationTitleKeys() throws {
        let koreanBundle = try #require(self.localizedBundle(for: "ko"))

        #expect(koreanBundle.localizedString(forKey: "Home", value: nil, table: nil) == "홈")
        #expect(koreanBundle.localizedString(forKey: "Explore", value: nil, table: nil) == "둘러보기")
        #expect(koreanBundle.localizedString(forKey: "Library", value: nil, table: nil) == "보관함")
        #expect(koreanBundle.localizedString(forKey: "Listening History", value: nil, table: nil) == "감상 기록")

        AppLocalization.setLanguage("en")
        defer { AppLocalization.setLanguage(nil) }

        #expect(AppLocalization.localizedString(forKey: "Home") == "Home")
        #expect(AppLocalization.localizedString(forKey: "Explore") == "Explore")
        #expect(AppLocalization.localizedString(forKey: "Library") == "Library")
        #expect(AppLocalization.localizedString(forKey: "Listening History") == "Listening History")
    }

    @Test("Language override applies to navigation title lookups via AppLocalization.bundle")
    func overrideBundleResolvesNavigationTitles() {
        AppLocalization.setLanguage("ko")
        defer { AppLocalization.setLanguage(nil) }

        let title = AppLocalization.localizedString(forKey: "Home")
        #expect(title == "홈")

        AppLocalization.setLanguage("en")
        let englishTitle = AppLocalization.localizedString(forKey: "Home")
        #expect(englishTitle == "Home")
    }

    @Test("Clearing language override reverts to base bundle")
    func clearingOverrideRevertsToBaseBundle() {
        AppLocalization.setLanguage("ko")
        AppLocalization.setLanguage(nil)

        #expect(AppLocalization.overrideBundle == nil)
        #expect(AppLocalization.bundle.bundleURL == AppLocalization.baseBundle.bundleURL)
    }
}
