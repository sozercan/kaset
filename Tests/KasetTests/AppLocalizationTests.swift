import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.service))
struct AppLocalizationTests {
    private var repositoryRoot: URL {
        let testFileURL = URL(fileURLWithPath: #filePath)
        return testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

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

    private func sourceCatalogStrings() throws -> [String: Any] {
        let catalogURL = self.repositoryRoot.appendingPathComponent("Sources/Kaset/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(catalog["strings"] as? [String: Any])
    }

    /// Helper to read a localized value directly from the source string catalog.
    private func sourceCatalogValue(key: String, localeIdentifier: String) throws -> String {
        let strings = try self.sourceCatalogStrings()
        let entry = try #require(strings[key] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        let localization = try #require(localizations[localeIdentifier] as? [String: Any])
        let stringUnit = try #require(localization["stringUnit"] as? [String: Any])

        return try #require(stringUnit["value"] as? String)
    }

    private func sourceCatalogKeys(localeIdentifier: String) throws -> Set<String> {
        let strings = try self.sourceCatalogStrings()
        return Set(strings.compactMap { key, value in
            guard let entry = value as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any],
                  localizations[localeIdentifier] != nil
            else { return nil }

            return key
        })
    }

    private func sourceLocalizationKeys(localeIdentifier: String) throws -> Set<String> {
        let stringsURL = self.repositoryRoot
            .appendingPathComponent("Sources/Kaset/Resources")
            .appendingPathComponent("\(localeIdentifier).lproj/Localizable.strings")
        let data = try Data(contentsOf: stringsURL)
        let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let strings = try #require(propertyList as? [String: String])
        return Set(strings.keys)
    }

    @Test("Supported localization resources have matching key sets")
    func supportedLocalizationResourcesHaveMatchingKeySets() throws {
        // English uses the catalog's source values and only has two format-order overrides.
        let localeCodes = SettingsManager.ContentLanguage.allCases
            .compactMap(\.languageCode)
            .filter { $0 != "en" }
        var catalogKeysByLocale: [String: Set<String>] = [:]
        var expectedKeys = Set<String>()

        for localeCode in localeCodes {
            let keys = try self.sourceCatalogKeys(localeIdentifier: localeCode)
            catalogKeysByLocale[localeCode] = keys
            expectedKeys.formUnion(keys)
        }

        for localeCode in localeCodes {
            let catalogKeys = try #require(catalogKeysByLocale[localeCode])
            let localizationKeys = try self.sourceLocalizationKeys(localeIdentifier: localeCode)
            let missingCatalogKeys = expectedKeys.subtracting(catalogKeys).sorted()
            let missingLocalizationKeys = expectedKeys.subtracting(localizationKeys).sorted()
            let unexpectedLocalizationKeys = localizationKeys.subtracting(expectedKeys).sorted()

            #expect(missingCatalogKeys.isEmpty, "\(localeCode) catalog is missing: \(missingCatalogKeys)")
            #expect(missingLocalizationKeys.isEmpty, "\(localeCode) strings file is missing: \(missingLocalizationKeys)")
            #expect(unexpectedLocalizationKeys.isEmpty, "\(localeCode) strings file has unexpected keys: \(unexpectedLocalizationKeys)")
        }
    }

    @Test("Runtime interpolation keys resolve carousel and OSStatus translations")
    func runtimeInterpolationKeysResolveTranslations() throws {
        let shelf = "Alben"
        let status: Int32 = -50
        let bundle = try #require(self.localizedBundle(for: "de"))
        let locale = Locale(identifier: "de")

        #expect(String(localized: "Scroll \(shelf) left", bundle: bundle, locale: locale) == "Alben nach links scrollen")
        #expect(String(localized: "Scroll \(shelf) right", bundle: bundle, locale: locale) == "Alben nach rechts scrollen")
        #expect(
            String(localized: "Couldn't install the audio I/O proc (\(status)).", bundle: bundle, locale: locale) ==
                "Der Audio-I/O-Proc konnte nicht installiert werden (-50)."
        )
        #expect(
            String(
                localized: "Couldn't capture Kaset's audio (status \(status)). Check Screen & System Audio Recording permission in System Settings.",
                bundle: bundle,
                locale: locale
            ) ==
                "Kasets Audio konnte nicht erfasst werden (Status -50). Prüfe die Berechtigung für Bildschirm- und Systemaudioaufnahme in den Systemeinstellungen."
        )

        #expect(try self.sourceCatalogValue(key: "Scroll %@ left", localeIdentifier: "de") == "%1$@ nach links scrollen")
        #expect(try self.sourceCatalogValue(key: "Scroll %@ right", localeIdentifier: "de") == "%1$@ nach rechts scrollen")
        #expect(try self.sourceCatalogValue(key: "Couldn't install the audio I/O proc (%d).", localeIdentifier: "de").contains("%d"))
        #expect(
            try self.sourceCatalogValue(
                key: "Couldn't capture Kaset's audio (status %d). Check Screen & System Audio Recording permission in System Settings.",
                localeIdentifier: "de"
            ).contains("%d")
        )
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

    @Test("Indonesian bundle localizes artist and subscribe strings")
    func indonesianLocalizationWorks() {
        let artist = self.localizedValue(key: "Artist", localeIdentifier: "id")
        let localizedText = self.localizedValue(key: "Subscribe %@", localeIdentifier: "id")
        let title = String(format: localizedText, locale: Locale(identifier: "id"), "34.6M")

        #expect(artist == "Artis")
        #expect(title.hasPrefix("Berlangganan"))
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

    @Test("Indonesian source catalog maps navigation and sidebar strings correctly")
    func indonesianSourceCatalogMapsAffectedStrings() throws {
        let expectedValues = [
            ("Home", "Beranda"),
            ("Search", "Cari"),
            ("Explore", "Jelajah"),
            ("Library", "Pustaka"),
            ("Hide lyrics explanation", "Sembunyikan penjelasan lirik"),
            ("Subscribe %@", "Berlangganan %@"),
        ]

        for (key, expectedValue) in expectedValues {
            #expect(try self.sourceCatalogValue(key: key, localeIdentifier: "id") == expectedValue)
            #expect(self.localizedValue(key: key, localeIdentifier: "id") == expectedValue)
        }
    }

    /// Guards against a recurrence of the French column misalignment fixed in
    /// this PR (introduced by #160, where the `fr` values were shifted onto the
    /// wrong keys). Asserts representative keys map to their known-good French
    /// values both in the source catalog and via the runtime `.lproj` override
    /// bundle, so a future shift fails CI rather than shipping silently —
    /// mirrors `indonesianSourceCatalogMapsAffectedStrings`.
    @Test("French source catalog maps affected strings correctly")
    func frenchSourceCatalogMapsAffectedStrings() throws {
        let expectedValues = [
            ("Account", "Compte"),
            ("Content Language", "Langue du contenu"),
            ("About", "À propos"),
            ("Updates", "Mises à jour"),
            ("Command Bar", "Barre de commandes"),
            ("Lyrics", "Paroles"),
        ]

        for (key, expectedValue) in expectedValues {
            #expect(try self.sourceCatalogValue(key: key, localeIdentifier: "fr") == expectedValue)
            #expect(self.localizedValue(key: key, localeIdentifier: "fr") == expectedValue)
        }
    }

    /// Verifies the renamed account-status key resolves through the runtime
    /// `.lproj` override bundles (not just the catalog), since the per-language
    /// `.lproj` files are the source the language override reads at runtime.
    @Test("Renamed signed-in status resolves in lproj override bundles")
    func renamedSignedInStatusResolvesInLprojBundles() {
        let expected = [
            ("fr", "Connecté à YouTube"),
            ("id", "Sudah masuk ke YouTube"),
            ("ko", "YouTube에 로그인됨"),
        ]
        for (locale, value) in expected {
            #expect(self.localizedValue(key: "Signed in to YouTube", localeIdentifier: locale) == value)
        }
    }

    @Test("Smart Shuffle strings resolve from runtime lproj bundles")
    func smartShuffleRuntimeStringsResolveFromLprojBundles() {
        let expectedValues = [
            ("ar", "الخلط الذكي"),
            ("de", "Intelligentes Mischen"),
            ("es", "Aleatorio inteligente"),
            ("fr", "Lecture aléatoire intelligente"),
            ("id", "Acak Cerdas"),
            ("it", "Shuffle intelligente"),
            ("ko", "스마트 셔플"),
            ("nl", "Slimme shuffle"),
            ("pl", "Inteligentne losowanie"),
            ("pt", "Aleatório inteligente"),
            ("ru", "Умное перемешивание"),
            ("sv", "Smart blandning"),
            ("tr", "Akıllı Karıştırma"),
            ("uk", "Розумне перемішування"),
        ]

        for (locale, expectedValue) in expectedValues {
            #expect(self.localizedValue(key: "Smart Shuffle", localeIdentifier: locale) == expectedValue)
        }
    }

    @Test("German bundle localizes artist and subscribe strings")
    func germanLocalizationWorks() {
        let artist = self.localizedValue(key: "Artist", localeIdentifier: "de")
        let localizedText = self.localizedValue(key: "Subscribe %@", localeIdentifier: "de")
        let title = String(format: localizedText, locale: Locale(identifier: "de"), "34.6M")

        #expect(artist == "Interpret")
        #expect(title.hasPrefix("Abonnieren"))
        #expect(title.contains("34.6M"))
        #expect(self.localizedValue(key: "Move Up", localeIdentifier: "de") == "Nach oben")
        #expect(self.localizedValue(key: "Add to Sidebar", localeIdentifier: "de") == "Zur Seitenleiste hinzufügen")
    }

    @Test("Spanish bundle localizes artist and subscribe strings")
    func spanishLocalizationWorks() {
        let artist = self.localizedValue(key: "Artist", localeIdentifier: "es")
        let localizedText = self.localizedValue(key: "Subscribe %@", localeIdentifier: "es")
        let title = String(format: localizedText, locale: Locale(identifier: "es"), "34.6M")

        #expect(artist == "Artista")
        #expect(title.hasPrefix("Suscribirse"))
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

    @Test("Italian bundle localizes artist and subscribe strings")
    func italianLocalizationWorks() {
        let artist = self.localizedValue(key: "Artist", localeIdentifier: "it")
        let localizedText = self.localizedValue(key: "Subscribe %@", localeIdentifier: "it")
        let title = String(format: localizedText, locale: Locale(identifier: "it"), "34.6M")

        #expect(artist == "Artista")
        #expect(title.hasPrefix("Abbonati"))
        #expect(title.contains("34.6M"))
    }

    @Test("Dutch bundle localizes artist and subscribe strings")
    func dutchLocalizationWorks() {
        let artist = self.localizedValue(key: "Artist", localeIdentifier: "nl")
        let localizedText = self.localizedValue(key: "Subscribe %@", localeIdentifier: "nl")
        let title = String(format: localizedText, locale: Locale(identifier: "nl"), "34.6M")

        #expect(artist == "Artiest")
        #expect(title.hasPrefix("Abonneren"))
        #expect(title.contains("34.6M"))
    }

    @Test("Polish bundle localizes artist and subscribe strings")
    func polishLocalizationWorks() {
        let artist = self.localizedValue(key: "Artist", localeIdentifier: "pl")
        let localizedText = self.localizedValue(key: "Subscribe %@", localeIdentifier: "pl")
        let title = String(format: localizedText, locale: Locale(identifier: "pl"), "34.6M")

        #expect(artist == "Artysta")
        #expect(title.hasPrefix("Subskrybuj"))
        #expect(title.contains("34.6M"))
    }

    @Test("Portuguese bundle localizes artist and subscribe strings")
    func portugueseLocalizationWorks() {
        let artist = self.localizedValue(key: "Artist", localeIdentifier: "pt")
        let localizedText = self.localizedValue(key: "Subscribe %@", localeIdentifier: "pt")
        let title = String(format: localizedText, locale: Locale(identifier: "pt"), "34.6M")

        #expect(artist == "Artista")
        #expect(title.hasPrefix("Subscrever"))
        #expect(title.contains("34.6M"))
    }

    @Test("Russian bundle localizes artist and subscribe strings")
    func russianLocalizationWorks() {
        let artist = self.localizedValue(key: "Artist", localeIdentifier: "ru")
        let localizedText = self.localizedValue(key: "Subscribe %@", localeIdentifier: "ru")
        let title = String(format: localizedText, locale: Locale(identifier: "ru"), "34.6M")

        #expect(artist == "Исполнитель")
        #expect(title.hasPrefix("Подписаться"))
        #expect(title.contains("34.6M"))
    }

    @Test("Swedish bundle localizes artist and subscribe strings")
    func swedishLocalizationWorks() {
        let artist = self.localizedValue(key: "Artist", localeIdentifier: "sv")
        let localizedText = self.localizedValue(key: "Subscribe %@", localeIdentifier: "sv")
        let title = String(format: localizedText, locale: Locale(identifier: "sv"), "34.6M")

        #expect(artist == "Artist")
        #expect(title.hasPrefix("Prenumerera"))
        #expect(title.contains("34.6M"))
    }

    @Test("Ukrainian bundle localizes artist and subscribe strings")
    func ukrainianLocalizationWorks() {
        let artist = self.localizedValue(key: "Artist", localeIdentifier: "uk")
        let localizedText = self.localizedValue(key: "Subscribe %@", localeIdentifier: "uk")
        let title = String(format: localizedText, locale: Locale(identifier: "uk"), "34.6M")

        #expect(artist == "Виконавець")
        #expect(title.hasPrefix("Підписатися"))
        #expect(title.contains("34.6M"))
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
