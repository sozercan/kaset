import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.service))
struct AppLocalizationTests {
    @Test("Bundle.module localizes artist strings in unit tests")
    func moduleBundleLocalizesArtistStrings() throws {
        let arabicBundle = try #require(self.localizedBundle(for: "ar"))

        #expect(arabicBundle.localizedString(forKey: "Artist", value: nil, table: nil) == "فنان")
    }

    @Test("Formatted subscribe label is localized as one phrase")
    func moduleBundleLocalizesFormattedSubscribeLabel() throws {
        let arabicBundle = try #require(self.localizedBundle(for: "ar"))
        let format = arabicBundle.localizedString(forKey: "Subscribe %@", value: nil, table: nil)
        let title = String(format: format, locale: Locale(identifier: "ar"), "34.6M")

        #expect(title.hasPrefix("اشترك"))
        #expect(title.contains("34.6M"))
    }

    @Test("Turkish bundle localizes artist and subscribe strings")
    func moduleBundleLocalizesTurkishStrings() throws {
        let turkishBundle = try #require(self.localizedBundle(for: "tr"))
        let format = turkishBundle.localizedString(forKey: "Subscribe %@", value: nil, table: nil)
        let title = String(format: format, locale: Locale(identifier: "tr"), "34.6M")

        #expect(turkishBundle.localizedString(forKey: "Artist", value: nil, table: nil) == "Sanatçı")
        #expect(title.hasPrefix("Abone Ol"))
        #expect(title.contains("34.6M"))
    }

    @Test("Korean bundle localizes artist and subscribe strings")
    func moduleBundleLocalizesKoreanStrings() throws {
        let koreanBundle = try #require(self.localizedBundle(for: "ko"))
        let format = koreanBundle.localizedString(forKey: "Subscribe %@", value: nil, table: nil)
        let title = String(format: format, locale: Locale(identifier: "ko"), "34.6M")

        #expect(koreanBundle.localizedString(forKey: "Artist", value: nil, table: nil) == "아티스트")
        #expect(title.hasPrefix("구독"))
        #expect(title.contains("34.6M"))
    }

    @Test("Indonesian bundle localizes artist and subscribe strings")
    func moduleBundleLocalizesIndonesianStrings() throws {
        let indonesianBundle = try #require(self.localizedBundle(for: "id"))
        let format = indonesianBundle.localizedString(forKey: "Subscribe %@", value: nil, table: nil)
        let title = String(format: format, locale: Locale(identifier: "id"), "34.6M")

        #expect(indonesianBundle.localizedString(forKey: "Artist", value: nil, table: nil) == "Artis")
        #expect(title.hasPrefix("Berlangganan"))
        #expect(title.contains("34.6M"))
    }

    @Test("Override bundle is only used for Kaset-owned bundles")
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
        let englishBundle = try #require(self.localizedBundle(for: "en"))

        // Korean lproj returns Korean translations
        #expect(koreanBundle.localizedString(forKey: "Home", value: nil, table: nil) == "홈")
        #expect(koreanBundle.localizedString(forKey: "Explore", value: nil, table: nil) == "둘러보기")
        #expect(koreanBundle.localizedString(forKey: "Library", value: nil, table: nil) == "보관함")
        #expect(koreanBundle.localizedString(forKey: "Listening History", value: nil, table: nil) == "감상 기록")

        // English lproj returns English strings
        #expect(englishBundle.localizedString(forKey: "Home", value: nil, table: nil) == "Home")
        #expect(englishBundle.localizedString(forKey: "Explore", value: nil, table: nil) == "Explore")
        #expect(englishBundle.localizedString(forKey: "Library", value: nil, table: nil) == "Library")
        #expect(englishBundle.localizedString(forKey: "Listening History", value: nil, table: nil) == "Listening History")
    }

    @Test("Language override applies to navigation title lookups via AppLocalization.bundle")
    func overrideBundleResolvesNavigationTitles() {
        // Set override to Korean
        AppLocalization.setLanguage("ko")
        defer { AppLocalization.setLanguage(nil) }

        let title = AppLocalization.bundle.localizedString(forKey: "Home", value: nil, table: nil)
        #expect(title == "홈")

        // Switch to English
        AppLocalization.setLanguage("en")
        let englishTitle = AppLocalization.bundle.localizedString(forKey: "Home", value: nil, table: nil)
        #expect(englishTitle == "Home")
    }

    @Test("Clearing language override reverts to base bundle")
    func clearingOverrideRevertsToBaseBundle() {
        AppLocalization.setLanguage("ko")
        AppLocalization.setLanguage(nil)

        #expect(AppLocalization.overrideBundle == nil)
        #expect(AppLocalization.bundle.bundleURL == AppLocalization.baseBundle.bundleURL)
    }

    private func localizedBundle(for localization: String) -> Bundle? {
        guard let bundlePath = AppLocalization.bundle.path(forResource: localization, ofType: "lproj") else {
            return nil
        }

        return Bundle(path: bundlePath)
    }
}
