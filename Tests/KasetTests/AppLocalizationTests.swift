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

    private func localizedBundle(for localization: String) -> Bundle? {
        guard let bundlePath = AppLocalization.bundle.path(forResource: localization, ofType: "lproj") else {
            return nil
        }

        return Bundle(path: bundlePath)
    }
}
