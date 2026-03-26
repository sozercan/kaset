import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.service))
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

    private func localizedBundle(for localization: String) -> Bundle? {
        guard let bundlePath = AppLocalization.bundle.path(forResource: localization, ofType: "lproj") else {
            return nil
        }

        return Bundle(path: bundlePath)
    }
}
