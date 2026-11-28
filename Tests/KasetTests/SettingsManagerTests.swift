import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.service))
@MainActor
struct SettingsManagerTests {
    private struct IsolatedSettings {
        let manager: SettingsManager
        let defaults: UserDefaults
        let suiteName: String
    }

    private func makeIsolatedManager() throws -> IsolatedSettings {
        let suiteName = "SettingsManagerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return IsolatedSettings(manager: SettingsManager(defaults: defaults), defaults: defaults, suiteName: suiteName)
    }

    @Test("LaunchPage has correct display names")
    func launchPageDisplayNames() {
        #expect(SettingsManager.LaunchPage.home.displayName == "Home")
        #expect(SettingsManager.LaunchPage.explore.displayName == "Explore")
        #expect(SettingsManager.LaunchPage.charts.displayName == "Charts")
        #expect(SettingsManager.LaunchPage.moodsAndGenres.displayName == "Moods & Genres")
        #expect(SettingsManager.LaunchPage.newReleases.displayName == "New Releases")
        #expect(SettingsManager.LaunchPage.likedMusic.displayName == "Liked Music")
        #expect(SettingsManager.LaunchPage.playlists.displayName == "Playlists")
        #expect(SettingsManager.LaunchPage.lastUsed.displayName == "Last Used")
    }

    @Test("LaunchPage rawValues are valid")
    func launchPageRawValues() {
        for page in SettingsManager.LaunchPage.allCases {
            let restored = SettingsManager.LaunchPage(rawValue: page.rawValue)
            #expect(restored == page)
        }
    }

    @Test("LaunchPage identifiers are unique")
    func launchPageIdentifiersUnique() {
        let ids = SettingsManager.LaunchPage.allCases.map(\.id)
        let uniqueIds = Set(ids)
        #expect(ids.count == uniqueIds.count)
    }

    @Test("LaunchPage converts to NavigationItem")
    func launchPageNavigationItem() {
        #expect(SettingsManager.LaunchPage.home.navigationItem == .home)
        #expect(SettingsManager.LaunchPage.explore.navigationItem == .explore)
        #expect(SettingsManager.LaunchPage.charts.navigationItem == .charts)
        #expect(SettingsManager.LaunchPage.moodsAndGenres.navigationItem == .moodsAndGenres)
        #expect(SettingsManager.LaunchPage.newReleases.navigationItem == .newReleases)
        #expect(SettingsManager.LaunchPage.likedMusic.navigationItem == .likedMusic)
        #expect(SettingsManager.LaunchPage.playlists.navigationItem == .library)
        #expect(SettingsManager.LaunchPage.lastUsed.navigationItem == .home)
    }

    @Test("Default showNowPlayingNotifications is true")
    func defaultShowNowPlayingNotifications() throws {
        let isolated = try self.makeIsolatedManager()
        let (manager, defaults, suiteName) = (isolated.manager, isolated.defaults, isolated.suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(manager.showNowPlayingNotifications == true)
    }

    @Test("Default hapticFeedbackEnabled is true")
    func defaultHapticFeedbackEnabled() throws {
        let isolated = try self.makeIsolatedManager()
        let (manager, defaults, suiteName) = (isolated.manager, isolated.defaults, isolated.suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(manager.hapticFeedbackEnabled == true)
    }

    @Test("Default rememberPlaybackSettings is false")
    func defaultRememberPlaybackSettings() throws {
        let isolated = try self.makeIsolatedManager()
        let (manager, defaults, suiteName) = (isolated.manager, isolated.defaults, isolated.suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(manager.rememberPlaybackSettings == false)
    }

    @Test("Default popOutVideoOnNavigateAway is true")
    func defaultPopOutVideoOnNavigateAway() throws {
        let isolated = try self.makeIsolatedManager()
        let (manager, defaults, suiteName) = (isolated.manager, isolated.defaults, isolated.suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(manager.popOutVideoOnNavigateAway == true)
    }

    @Test("popOutVideoOnNavigateAway persists to UserDefaults")
    func popOutVideoOnNavigateAwayPersists() throws {
        let isolated = try self.makeIsolatedManager()
        let (manager, defaults, suiteName) = (isolated.manager, isolated.defaults, isolated.suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        manager.popOutVideoOnNavigateAway = false
        #expect(defaults.bool(forKey: SettingsManager.Keys.popOutVideoOnNavigateAway) == false)

        manager.popOutVideoOnNavigateAway = true
        #expect(defaults.bool(forKey: SettingsManager.Keys.popOutVideoOnNavigateAway) == true)
    }

    @Test("Missing showYouTubeControlsOnVideo value loads as false")
    func missingShowYouTubeControlsOnVideoLoadsAsFalse() throws {
        let suiteName = "SettingsManagerTests.showYouTubeControlsOnVideo.missing.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.removePersistentDomain(forName: suiteName)

        #expect(SettingsManager.loadShowYouTubeControlsOnVideo(from: defaults) == false)
    }

    @Test("Stored true showYouTubeControlsOnVideo value loads as true")
    func storedTrueShowYouTubeControlsOnVideoLoadsAsTrue() throws {
        let suiteName = "SettingsManagerTests.showYouTubeControlsOnVideo.true.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: SettingsManager.Keys.showYouTubeControlsOnVideo)

        #expect(SettingsManager.loadShowYouTubeControlsOnVideo(from: defaults) == true)
    }

    @Test("showYouTubeControlsOnVideo persists to UserDefaults")
    func showYouTubeControlsOnVideoPersists() throws {
        let isolated = try self.makeIsolatedManager()
        let (manager, defaults, suiteName) = (isolated.manager, isolated.defaults, isolated.suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        manager.showYouTubeControlsOnVideo = true
        #expect(defaults.bool(forKey: SettingsManager.Keys.showYouTubeControlsOnVideo) == true)

        manager.showYouTubeControlsOnVideo = false
        #expect(defaults.bool(forKey: SettingsManager.Keys.showYouTubeControlsOnVideo) == false)
    }

    @Test("Missing keepYouTubeVideoOnTop value loads as false")
    func missingKeepYouTubeVideoOnTopLoadsAsFalse() throws {
        let suiteName = "SettingsManagerTests.keepYouTubeVideoOnTop.missing.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.removePersistentDomain(forName: suiteName)

        #expect(SettingsManager.loadKeepYouTubeVideoOnTop(from: defaults) == false)
    }

    @Test("Stored true keepYouTubeVideoOnTop value loads as true")
    func storedTrueKeepYouTubeVideoOnTopLoadsAsTrue() throws {
        let suiteName = "SettingsManagerTests.keepYouTubeVideoOnTop.true.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: SettingsManager.Keys.keepYouTubeVideoOnTop)

        #expect(SettingsManager.loadKeepYouTubeVideoOnTop(from: defaults) == true)
    }

    @Test("Stored false keepYouTubeVideoOnTop value loads as false")
    func storedFalseKeepYouTubeVideoOnTopLoadsAsFalse() throws {
        let suiteName = "SettingsManagerTests.keepYouTubeVideoOnTop.false.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: SettingsManager.Keys.keepYouTubeVideoOnTop)

        #expect(SettingsManager.loadKeepYouTubeVideoOnTop(from: defaults) == false)
    }

    @Test("keepYouTubeVideoOnTop persists to isolated UserDefaults")
    func keepYouTubeVideoOnTopPersists() throws {
        let isolated = try self.makeIsolatedManager()
        let (manager, defaults, suiteName) = (isolated.manager, isolated.defaults, isolated.suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = SettingsManager.Keys.keepYouTubeVideoOnTop

        manager.keepYouTubeVideoOnTop = true
        #expect(defaults.object(forKey: key) as? Bool == true)

        manager.keepYouTubeVideoOnTop = false
        #expect(defaults.object(forKey: key) as? Bool == false)
    }

    @Test("Disabling rememberPlaybackSettings clears persisted values")
    func disablingRememberPlaybackSettingsClearsValues() throws {
        let isolated = try self.makeIsolatedManager()
        let (manager, defaults, suiteName) = (isolated.manager, isolated.defaults, isolated.suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let shuffleKey = "playerShuffleEnabled"
        let repeatKey = "playerRepeatMode"

        defaults.set(true, forKey: shuffleKey)
        defaults.set("all", forKey: repeatKey)

        manager.rememberPlaybackSettings = true
        manager.rememberPlaybackSettings = false

        #expect(defaults.object(forKey: shuffleKey) == nil)
        #expect(defaults.object(forKey: repeatKey) == nil)
    }

    @Test("Content languages expose stable API codes in locale-code order")
    func contentLanguagesExposeAPICodesInLocaleCodeOrder() {
        let expectedCodes = [
            "ar", "de", "en", "es", "fr", "id", "it", "ja", "ko", "nl", "pl", "pt", "ru", "sv", "tr", "uk",
            "zh-Hans", "zh-Hant",
        ]
        let languages = SettingsManager.ContentLanguage.allCases

        #expect(languages.first == .system)
        #expect(languages.dropFirst().compactMap(\.languageCode) == expectedCodes)
    }

    @Test("Chinese content languages send their bundle code as the API code")
    func chineseContentLanguagesSendBundleCodeAsAPICode() {
        #expect(SettingsManager.ContentLanguage.simplifiedChinese.apiLanguageCode == "zh-Hans")
        #expect(SettingsManager.ContentLanguage.traditionalChinese.apiLanguageCode == "zh-Hant")
    }

    @Test("System content language delegates to the current locale")
    func systemContentLanguageDelegatesToCurrentLocale() {
        let expectedCode = SettingsManager.ContentLanguage.system.apiLanguageCode(for: Locale.current)
        #expect(SettingsManager.ContentLanguage.system.apiLanguageCode == expectedCode)
    }

    @Test(
        "System content language uses the language code for non-Chinese locales",
        arguments: [
            ("fr-FR", "fr"),
            ("pt-BR", "pt"),
        ]
    )
    func systemContentLanguageUsesLanguageCode(localeIdentifier: String, expectedCode: String) {
        let locale = Locale(identifier: localeIdentifier)

        #expect(SettingsManager.ContentLanguage.system.apiLanguageCode(for: locale) == expectedCode)
    }

    @Test("System content language falls back to English without a language code")
    func systemContentLanguageFallsBackToEnglish() {
        let localeWithoutLanguageCode = Locale(identifier: "")

        #expect(SettingsManager.ContentLanguage.system.apiLanguageCode(for: localeWithoutLanguageCode) == "en")
    }

    @Test(
        "System content language preserves the inferred Chinese script",
        arguments: [
            ("zh-CN", "zh-Hans"),
            ("zh-TW", "zh-Hant"),
            ("zh-HK", "zh-Hant"),
        ]
    )
    func systemContentLanguagePreservesChineseScript(localeIdentifier: String, expectedCode: String) {
        let locale = Locale(identifier: localeIdentifier)

        #expect(SettingsManager.ContentLanguage.system.apiLanguageCode(for: locale) == expectedCode)
    }

    @Test("Changing content language invalidates API cache and updates localization bundle")
    func changingContentLanguageInvalidatesCacheAndUpdatesLocalizationBundle() throws {
        let suiteName = "SettingsManagerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let manager = SettingsManager(defaults: defaults, applyLocalization: AppLocalization.setLanguage)
        let originalSharedLanguage = SettingsManager.shared.contentLanguage

        defer {
            APICache.shared.invalidateAll()
            AppLocalization.setLanguage(originalSharedLanguage.languageCode)
            defaults.removePersistentDomain(forName: suiteName)
        }

        manager.contentLanguage = .english
        APICache.shared.set(key: "browse:test-home", data: ["title": "Home"], ttl: 60)

        #expect(APICache.shared.get(key: "browse:test-home") != nil)

        manager.contentLanguage = .korean

        #expect(APICache.shared.get(key: "browse:test-home") == nil)
        #expect(AppLocalization.bundle.localizedString(forKey: "Home", value: nil, table: nil) == "홈")
    }

    @Test("launchPage returns defaultLaunchPage for non-lastUsed")
    func launchPageReturnsDefault() throws {
        let isolated = try self.makeIsolatedManager()
        let (manager, defaults, suiteName) = (isolated.manager, isolated.defaults, isolated.suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        manager.defaultLaunchPage = .explore

        #expect(manager.launchPage == .explore)
    }

    @Test("launchPage returns lastUsedPage when set to lastUsed")
    func launchPageReturnsLastUsed() throws {
        let isolated = try self.makeIsolatedManager()
        let (manager, defaults, suiteName) = (isolated.manager, isolated.defaults, isolated.suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        manager.defaultLaunchPage = .lastUsed
        manager.lastUsedPage = .charts

        #expect(manager.launchPage == .charts)
    }

    @Test("launchNavigationItem returns correct item")
    func launchNavigationItemReturnsCorrect() throws {
        let isolated = try self.makeIsolatedManager()
        let (manager, defaults, suiteName) = (isolated.manager, isolated.defaults, isolated.suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        manager.defaultLaunchPage = .likedMusic

        #expect(manager.launchNavigationItem == .likedMusic)
    }

    @Test("MediaControlStyle has correct display names")
    func mediaControlStyleDisplayNames() {
        #expect(SettingsManager.MediaControlStyle.skipForwardBackward.displayName == "Skip Forward/Backward")
        #expect(SettingsManager.MediaControlStyle.nextPreviousTrack.displayName == "Next/Previous Track")
    }

    @Test("MediaControlStyle rawValues roundtrip correctly")
    func mediaControlStyleRawValues() {
        for style in SettingsManager.MediaControlStyle.allCases {
            let restored = SettingsManager.MediaControlStyle(rawValue: style.rawValue)
            #expect(restored == style)
        }
    }

    @Test("MediaControlStyle identifiers are unique")
    func mediaControlStyleIdentifiersUnique() {
        let ids = SettingsManager.MediaControlStyle.allCases.map(\.id)
        let uniqueIds = Set(ids)
        #expect(ids.count == uniqueIds.count)
    }

    @Test("Default mediaControlStyle is nextPreviousTrack")
    func defaultMediaControlStyle() throws {
        let isolated = try self.makeIsolatedManager()
        let (manager, defaults, suiteName) = (isolated.manager, isolated.defaults, isolated.suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(manager.mediaControlStyle == .nextPreviousTrack)
    }

    @Test("PlaybackAudioQuality has correct display names")
    func playbackAudioQualityDisplayNames() {
        #expect(SettingsManager.PlaybackAudioQuality.auto.displayName == "Auto")
        #expect(SettingsManager.PlaybackAudioQuality.low.displayName == "Low")
        #expect(SettingsManager.PlaybackAudioQuality.normal.displayName == "Normal")
        #expect(SettingsManager.PlaybackAudioQuality.high.displayName == "High")
    }

    @Test("PlaybackAudioQuality rawValues roundtrip correctly")
    func playbackAudioQualityRawValues() {
        for quality in SettingsManager.PlaybackAudioQuality.allCases {
            let restored = SettingsManager.PlaybackAudioQuality(rawValue: quality.rawValue)
            #expect(restored == quality)
        }
    }

    @Test("PlaybackAudioQuality identifiers are unique")
    func playbackAudioQualityIdentifiersUnique() {
        let ids = SettingsManager.PlaybackAudioQuality.allCases.map(\.id)
        let uniqueIds = Set(ids)
        #expect(ids.count == uniqueIds.count)
    }

    @Test("PlaybackAudioQuality has all expected cases")
    func playbackAudioQualityAllCasesCovered() {
        #expect(SettingsManager.PlaybackAudioQuality.allCases.count == 4)
    }

    @Test("All LaunchPage cases are covered")
    func allLaunchPageCasesCovered() {
        #expect(SettingsManager.LaunchPage.allCases.count == 8)
    }
}
