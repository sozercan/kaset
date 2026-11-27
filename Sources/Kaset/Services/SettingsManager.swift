import Foundation
import Observation

@MainActor
@Observable
final class SettingsManager {
    static let shared = SettingsManager()
    nonisolated static let defaultAmbientBackdropStyle: AmbientBackdropStyle = .soft

    enum Keys {
        static let appearance = "settings.appearance"
        static let appSource = "settings.appSource"
        static let appExperience = "settings.appExperience"
        static let showNowPlayingNotifications = "settings.showNowPlayingNotifications"
        static let defaultLaunchPage = "settings.defaultLaunchPage"
        static let hapticFeedbackEnabled = "settings.hapticFeedbackEnabled"
        static let rememberPlaybackSettings = "settings.rememberPlaybackSettings"
        static let lastFMEnabled = "settings.lastFMEnabled"
        static let enabledServices = "settings.enabledServices"
        static let scrobblePercentThreshold = "settings.scrobblePercentThreshold"
        static let scrobbleMinSeconds = "settings.scrobbleMinSeconds"
        static let mediaControlStyle = "settings.mediaControlStyle"
        static let playbackAudioQuality = "settings.playbackAudioQuality"
        static let syncedLyricsEnabled = "settings.syncedLyricsEnabled"
        static let romanizationEnabled = "settings.romanizationEnabled"
        static let contentLanguage = "settings.contentLanguage"
        static let keepMiniPlayerOnTop = "settings.keepMiniPlayerOnTop"
        static let keepYouTubeVideoOnTop = "settings.keepYouTubeVideoOnTop"
        static let smartShuffleEnabled = "settings.smartShuffleEnabled"
        static let smartShuffleSuggestEveryN = "settings.smartShuffleSuggestEveryN"
        static let smartShuffleBurst = "settings.smartShuffleBurst"
        static let smartShuffleSuggestionsAhead = "settings.smartShuffleSuggestionsAhead"
        static let ambientBackdropEnabled = "settings.ambientBackdropEnabled"
        static let ambientBackdropStyle = "settings.ambientBackdropStyle"
        static let popOutVideoOnNavigateAway = "settings.popOutVideoOnNavigateAway"
        static let showYouTubeControlsOnVideo = "settings.showYouTubeControlsOnVideo"
        #if DEBUG
            static let useLegacyMacOS15UI = "settings.debug.useLegacyMacOS15UI"
        #endif
    }

    enum LaunchPage: String, CaseIterable, Identifiable {
        case home
        case explore
        case charts
        case moodsAndGenres
        case newReleases
        case likedMusic
        case playlists
        case lastUsed

        var id: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .home: String(localized: "Home")
            case .explore: String(localized: "Explore")
            case .charts: String(localized: "Charts")
            case .moodsAndGenres: String(localized: "Moods & Genres")
            case .newReleases: String(localized: "New Releases")
            case .likedMusic: String(localized: "Liked Music")
            case .playlists: String(localized: "Playlists")
            case .lastUsed: String(localized: "Last Used")
            }
        }

        var navigationItem: NavigationItem {
            switch self {
            case .home: .home
            case .explore: .explore
            case .charts: .charts
            case .moodsAndGenres: .moodsAndGenres
            case .newReleases: .newReleases
            case .likedMusic: .likedMusic
            case .playlists: .library
            case .lastUsed: .home
            }
        }
    }

    enum ContentLanguage: String, CaseIterable, Identifiable {
        case system
        case arabic
        case german
        case english
        case spanish
        case french
        case indonesian
        case italian
        case japanese
        case korean
        case dutch
        case polish
        case portuguese
        case russian
        case swedish
        case turkish
        case ukrainian
        case simplifiedChinese
        case traditionalChinese

        var id: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .system: String(localized: "System Default")
            case .arabic: "العربية"
            case .dutch: "Nederlands"
            case .english: "English"
            case .french: "Français"
            case .german: "Deutsch"
            case .indonesian: "Bahasa Indonesia"
            case .italian: "Italiano"
            case .japanese: "日本語"
            case .korean: "한국어"
            case .polish: "Polski"
            case .portuguese: "Português"
            case .russian: "Русский"
            case .spanish: "Español"
            case .simplifiedChinese: "简体中文"
            case .swedish: "Svenska"
            case .traditionalChinese: "繁體中文"
            case .turkish: "Türkçe"
            case .ukrainian: "Українська"
            }
        }

        var languageCode: String? {
            switch self {
            case .system: nil
            case .arabic: "ar"
            case .dutch: "nl"
            case .english: "en"
            case .french: "fr"
            case .german: "de"
            case .indonesian: "id"
            case .italian: "it"
            case .japanese: "ja"
            case .korean: "ko"
            case .polish: "pl"
            case .portuguese: "pt"
            case .russian: "ru"
            case .spanish: "es"
            case .simplifiedChinese: "zh-Hans"
            case .swedish: "sv"
            case .traditionalChinese: "zh-Hant"
            case .turkish: "tr"
            case .ukrainian: "uk"
            }
        }

        var apiLanguageCode: String {
            self.apiLanguageCode(for: Locale.current)
        }

        func apiLanguageCode(for systemLocale: Locale) -> String {
            if let languageCode = self.languageCode {
                return languageCode
            }

            let language = systemLocale.language
            guard let languageCode = language.languageCode?.identifier else {
                return "en"
            }

            return switch (languageCode, language.script?.identifier) {
            case ("zh", "Hans"): "zh-Hans"
            case ("zh", "Hant"): "zh-Hant"
            default: languageCode
            }
        }

        var locale: Locale {
            if let code = self.languageCode {
                Locale(identifier: code)
            } else {
                Locale.current
            }
        }
    }

    enum MediaControlStyle: String, CaseIterable, Identifiable {
        case skipForwardBackward
        case nextPreviousTrack

        var id: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .skipForwardBackward: "Skip Forward/Backward"
            case .nextPreviousTrack: "Next/Previous Track"
            }
        }
    }

    enum PlaybackAudioQuality: String, CaseIterable, Identifiable {
        case auto
        case low
        case normal
        case high

        var id: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .auto: "Auto"
            case .low: "Low"
            case .normal: "Normal"
            case .high: "High"
            }
        }
    }

    var appearance: AppAppearance {
        didSet {
            guard self.appearance != oldValue else { return }
            UserDefaults.standard.set(self.appearance.rawValue, forKey: Keys.appearance)
            self.appearance.apply()
        }
    }

    var appSource: AppSource {
        didSet {
            let resolved = self.appExperience.resolvedSource(for: self.appSource)
            if resolved != self.appSource {
                self.appSource = resolved
                return
            }
            UserDefaults.standard.set(self.appSource.rawValue, forKey: Keys.appSource)
        }
    }

    var appExperience: AppExperience {
        didSet {
            UserDefaults.standard.set(self.appExperience.rawValue, forKey: Keys.appExperience)
            if let enforcedSource = self.appExperience.enforcedSource, self.appSource != enforcedSource {
                self.appSource = enforcedSource
            }
        }
    }

    var showNowPlayingNotifications: Bool {
        didSet {
            UserDefaults.standard.set(self.showNowPlayingNotifications, forKey: Keys.showNowPlayingNotifications)
        }
    }

    var defaultLaunchPage: LaunchPage {
        didSet {
            UserDefaults.standard.set(self.defaultLaunchPage.rawValue, forKey: Keys.defaultLaunchPage)
        }
    }

    var hapticFeedbackEnabled: Bool {
        didSet {
            UserDefaults.standard.set(self.hapticFeedbackEnabled, forKey: Keys.hapticFeedbackEnabled)
        }
    }

    var rememberPlaybackSettings: Bool {
        didSet {
            UserDefaults.standard.set(self.rememberPlaybackSettings, forKey: Keys.rememberPlaybackSettings)
            if !self.rememberPlaybackSettings {
                UserDefaults.standard.removeObject(forKey: "playerShuffleEnabled")
                UserDefaults.standard.removeObject(forKey: "playerShuffleMode")
                UserDefaults.standard.removeObject(forKey: "playerRepeatMode")
            }
        }
    }

    var mediaControlStyle: MediaControlStyle {
        didSet {
            UserDefaults.standard.set(self.mediaControlStyle.rawValue, forKey: Keys.mediaControlStyle)
        }
    }

    var playbackAudioQuality: PlaybackAudioQuality {
        didSet {
            UserDefaults.standard.set(self.playbackAudioQuality.rawValue, forKey: Keys.playbackAudioQuality)
        }
    }

    private var enabledServices: [String: Bool] {
        didSet {
            UserDefaults.standard.set(self.enabledServices, forKey: Keys.enabledServices)
        }
    }

    func isServiceEnabled(_ serviceName: String) -> Bool {
        self.enabledServices[serviceName] ?? false
    }

    func setServiceEnabled(_ serviceName: String, _ enabled: Bool) {
        self.enabledServices[serviceName] = enabled
    }

    var lastFMEnabled: Bool {
        get { self.isServiceEnabled("Last.fm") }
        set { self.setServiceEnabled("Last.fm", newValue) }
    }

    var scrobblePercentThreshold: Double {
        didSet {
            UserDefaults.standard.set(self.scrobblePercentThreshold, forKey: Keys.scrobblePercentThreshold)
        }
    }

    var scrobbleMinSeconds: TimeInterval {
        didSet {
            UserDefaults.standard.set(self.scrobbleMinSeconds, forKey: Keys.scrobbleMinSeconds)
        }
    }

    var lastUsedPage: LaunchPage = .home

    var syncedLyricsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(self.syncedLyricsEnabled, forKey: Keys.syncedLyricsEnabled)
        }
    }

    var romanizationEnabled: Bool {
        didSet {
            UserDefaults.standard.set(self.romanizationEnabled, forKey: Keys.romanizationEnabled)
        }
    }

    var keepMiniPlayerOnTop: Bool {
        didSet {
            UserDefaults.standard.set(self.keepMiniPlayerOnTop, forKey: Keys.keepMiniPlayerOnTop)
        }
    }

    var keepYouTubeVideoOnTop: Bool {
        didSet {
            UserDefaults.standard.set(self.keepYouTubeVideoOnTop, forKey: Keys.keepYouTubeVideoOnTop)
        }
    }

    static let smartShuffleSuggestEveryNDefault = 3
    static let smartShuffleSuggestEveryNRange = 1 ... 6
    static let smartShuffleBurstDefault = 1
    static let smartShuffleBurstRange = 1 ... 5
    static let smartShuffleSuggestionsAheadDefault = 20
    static let smartShuffleSuggestionsAheadRange = 5 ... 100

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    var smartShuffleEnabled: Bool {
        didSet {
            UserDefaults.standard.set(self.smartShuffleEnabled, forKey: Keys.smartShuffleEnabled)
        }
    }

    var smartShuffleSuggestEveryN: Int {
        didSet {
            let clamped = Self.clamp(self.smartShuffleSuggestEveryN, to: Self.smartShuffleSuggestEveryNRange)
            if clamped != self.smartShuffleSuggestEveryN {
                self.smartShuffleSuggestEveryN = clamped
            }
            UserDefaults.standard.set(clamped, forKey: Keys.smartShuffleSuggestEveryN)
        }
    }

    var smartShuffleBurst: Int {
        didSet {
            let clamped = Self.clamp(self.smartShuffleBurst, to: Self.smartShuffleBurstRange)
            if clamped != self.smartShuffleBurst {
                self.smartShuffleBurst = clamped
            }
            UserDefaults.standard.set(clamped, forKey: Keys.smartShuffleBurst)
        }
    }

    var smartShuffleSuggestionsAhead: Int {
        didSet {
            let clamped = Self.clamp(self.smartShuffleSuggestionsAhead, to: Self.smartShuffleSuggestionsAheadRange)
            if clamped != self.smartShuffleSuggestionsAhead {
                self.smartShuffleSuggestionsAhead = clamped
            }
            UserDefaults.standard.set(clamped, forKey: Keys.smartShuffleSuggestionsAhead)
        }
    }

    var ambientBackdropEnabled: Bool {
        didSet {
            UserDefaults.standard.set(self.ambientBackdropEnabled, forKey: Keys.ambientBackdropEnabled)
        }
    }

    var ambientBackdropStyle: AmbientBackdropStyle {
        didSet {
            UserDefaults.standard.set(self.ambientBackdropStyle.rawValue, forKey: Keys.ambientBackdropStyle)
        }
    }

    var popOutVideoOnNavigateAway: Bool {
        didSet {
            UserDefaults.standard.set(self.popOutVideoOnNavigateAway, forKey: Keys.popOutVideoOnNavigateAway)
        }
    }

    var showYouTubeControlsOnVideo: Bool {
        didSet {
            UserDefaults.standard.set(self.showYouTubeControlsOnVideo, forKey: Keys.showYouTubeControlsOnVideo)
        }
    }

    var resolvedAmbientStyle: AmbientBackdropStyle {
        Self.resolveAmbientStyle(
            enabled: self.ambientBackdropEnabled,
            preferredStyle: self.ambientBackdropStyle
        )
    }

    nonisolated static func resolveAmbientStyle(
        enabled: Bool,
        preferredStyle: AmbientBackdropStyle
    ) -> AmbientBackdropStyle {
        guard enabled, preferredStyle != .off else { return .off }
        return preferredStyle
    }

    var contentLanguage: ContentLanguage {
        didSet {
            UserDefaults.standard.set(self.contentLanguage.rawValue, forKey: Keys.contentLanguage)
            AppLocalization.setLanguage(self.contentLanguage.languageCode)
            APICache.shared.invalidateAll()
        }
    }

    #if DEBUG
        var useLegacyMacOS15UI: Bool {
            didSet {
                UserDefaults.standard.set(self.useLegacyMacOS15UI, forKey: Keys.useLegacyMacOS15UI)
            }
        }
    #else
        let useLegacyMacOS15UI = false
    #endif

    static func loadKeepYouTubeVideoOnTop(from defaults: UserDefaults) -> Bool {
        defaults.object(forKey: Keys.keepYouTubeVideoOnTop) as? Bool ?? false
    }

    static func loadShowYouTubeControlsOnVideo(from defaults: UserDefaults) -> Bool {
        defaults.object(forKey: Keys.showYouTubeControlsOnVideo) as? Bool ?? false
    }

    static func loadAppearance(from defaults: UserDefaults) -> AppAppearance {
        defaults.string(forKey: Keys.appearance).flatMap(AppAppearance.init(rawValue:)) ?? .system
    }

    static func loadAppExperience(from defaults: UserDefaults) -> AppExperience {
        defaults.string(forKey: Keys.appExperience).flatMap(AppExperience.init(rawValue:)) ?? .both
    }

    static func loadAppSource(from defaults: UserDefaults, experience: AppExperience) -> AppSource {
        let stored = defaults.string(forKey: Keys.appSource).flatMap(AppSource.init(rawValue:)) ?? .music
        return experience.resolvedSource(for: stored)
    }

    private init() {
        self.appearance = Self.loadAppearance(from: UserDefaults.standard)
        self.showNowPlayingNotifications = UserDefaults.standard.object(forKey: Keys.showNowPlayingNotifications) as? Bool ?? true
        self.hapticFeedbackEnabled = UserDefaults.standard.object(forKey: Keys.hapticFeedbackEnabled) as? Bool ?? true
        self.rememberPlaybackSettings = UserDefaults.standard.object(forKey: Keys.rememberPlaybackSettings) as? Bool ?? false

        if let stored = UserDefaults.standard.dictionary(forKey: Keys.enabledServices) as? [String: Bool] {
            self.enabledServices = stored
        } else if let legacyEnabled = UserDefaults.standard.object(forKey: Keys.lastFMEnabled) as? Bool {
            self.enabledServices = ["Last.fm": legacyEnabled]
        } else {
            self.enabledServices = [:]
        }
        self.scrobblePercentThreshold = UserDefaults.standard.object(forKey: Keys.scrobblePercentThreshold) as? Double ?? 0.5
        self.scrobbleMinSeconds = UserDefaults.standard.object(forKey: Keys.scrobbleMinSeconds) as? Double ?? 240
        self.syncedLyricsEnabled = UserDefaults.standard.object(forKey: Keys.syncedLyricsEnabled) as? Bool ?? true
        self.romanizationEnabled = UserDefaults.standard.object(forKey: Keys.romanizationEnabled) as? Bool ?? true
        self.keepMiniPlayerOnTop = UserDefaults.standard.object(forKey: Keys.keepMiniPlayerOnTop) as? Bool ?? false
        self.keepYouTubeVideoOnTop = Self.loadKeepYouTubeVideoOnTop(from: UserDefaults.standard)
        self.smartShuffleEnabled = UserDefaults.standard.object(forKey: Keys.smartShuffleEnabled) as? Bool ?? true
        self.smartShuffleSuggestEveryN = Self.clamp(
            UserDefaults.standard.object(forKey: Keys.smartShuffleSuggestEveryN) as? Int ?? Self.smartShuffleSuggestEveryNDefault,
            to: Self.smartShuffleSuggestEveryNRange
        )
        self.smartShuffleBurst = Self.clamp(
            UserDefaults.standard.object(forKey: Keys.smartShuffleBurst) as? Int ?? Self.smartShuffleBurstDefault,
            to: Self.smartShuffleBurstRange
        )
        self.smartShuffleSuggestionsAhead = Self.clamp(
            UserDefaults.standard.object(forKey: Keys.smartShuffleSuggestionsAhead) as? Int ?? Self.smartShuffleSuggestionsAheadDefault,
            to: Self.smartShuffleSuggestionsAheadRange
        )
        self.ambientBackdropEnabled = UserDefaults.standard.object(forKey: Keys.ambientBackdropEnabled) as? Bool ?? true
        self.popOutVideoOnNavigateAway = UserDefaults.standard.object(forKey: Keys.popOutVideoOnNavigateAway) as? Bool ?? true
        self.showYouTubeControlsOnVideo = Self.loadShowYouTubeControlsOnVideo(from: UserDefaults.standard)
        #if DEBUG
            self.useLegacyMacOS15UI = UserDefaults.standard.object(forKey: Keys.useLegacyMacOS15UI) as? Bool ?? false
        #endif

        if let rawValue = UserDefaults.standard.string(forKey: Keys.mediaControlStyle),
           let style = MediaControlStyle(rawValue: rawValue)
        {
            self.mediaControlStyle = style
        } else {
            self.mediaControlStyle = .nextPreviousTrack
        }

        if let rawValue = UserDefaults.standard.string(forKey: Keys.playbackAudioQuality),
           let quality = PlaybackAudioQuality(rawValue: rawValue)
        {
            self.playbackAudioQuality = quality
        } else {
            self.playbackAudioQuality = .auto
        }

        if let rawValue = UserDefaults.standard.string(forKey: Keys.ambientBackdropStyle),
           let style = AmbientBackdropStyle(rawValue: rawValue),
           style != .off
        {
            self.ambientBackdropStyle = style
        } else {
            self.ambientBackdropStyle = Self.defaultAmbientBackdropStyle
        }

        if let rawValue = UserDefaults.standard.string(forKey: Keys.defaultLaunchPage),
           let page = LaunchPage(rawValue: rawValue)
        {
            self.defaultLaunchPage = page
        } else {
            self.defaultLaunchPage = .home
        }

        if let rawValue = UserDefaults.standard.string(forKey: Keys.contentLanguage),
           let language = ContentLanguage(rawValue: rawValue)
        {
            self.contentLanguage = language
        } else {
            self.contentLanguage = .system
        }

        let experience = Self.loadAppExperience(from: UserDefaults.standard)
        self.appExperience = experience
        self.appSource = Self.loadAppSource(from: UserDefaults.standard, experience: experience)

        AppLocalization.setLanguage(self.contentLanguage.languageCode)

        if UserDefaults.standard.object(forKey: Keys.enabledServices) == nil,
           UserDefaults.standard.object(forKey: Keys.lastFMEnabled) != nil
        {
            UserDefaults.standard.set(self.enabledServices, forKey: Keys.enabledServices)
            UserDefaults.standard.removeObject(forKey: Keys.lastFMEnabled)
        }
    }

    var launchPage: LaunchPage {
        switch self.defaultLaunchPage {
        case .lastUsed:
            self.lastUsedPage
        default:
            self.defaultLaunchPage
        }
    }

    var launchNavigationItem: NavigationItem {
        self.launchPage.navigationItem
    }
}
