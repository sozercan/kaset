import Foundation
import Observation

/// Manages user preferences persisted via UserDefaults.
@MainActor
@Observable
final class SettingsManager {
    static let shared = SettingsManager()
    nonisolated static let defaultAmbientBackdropStyle: AmbientBackdropStyle = .soft

    // MARK: - Settings Keys

    enum Keys {
        static let appSource = "settings.appSource"
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
        static let smartShuffleEnabled = "settings.smartShuffleEnabled"
        static let smartShuffleSuggestEveryN = "settings.smartShuffleSuggestEveryN"
        static let smartShuffleBurst = "settings.smartShuffleBurst"
        static let smartShuffleSuggestionsAhead = "settings.smartShuffleSuggestionsAhead"
        static let ambientBackdropEnabled = "settings.ambientBackdropEnabled"
        static let ambientBackdropStyle = "settings.ambientBackdropStyle"
        static let popOutVideoOnNavigateAway = "settings.popOutVideoOnNavigateAway"
        #if DEBUG
            static let useLegacyMacOS15UI = "settings.debug.useLegacyMacOS15UI"
        #endif
    }

    // MARK: - Launch Page Options

    /// Available pages to launch the app with.
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

        /// Converts LaunchPage to NavigationItem for navigation.
        var navigationItem: NavigationItem {
            switch self {
            case .home: .home
            case .explore: .explore
            case .charts: .charts
            case .moodsAndGenres: .moodsAndGenres
            case .newReleases: .newReleases
            case .likedMusic: .likedMusic
            case .playlists: .library
            case .lastUsed: .home // Fallback, actual value comes from lastUsedPage
            }
        }
    }

    // MARK: - Content Language

    /// Available language options for app UI localization.
    enum ContentLanguage: String, CaseIterable, Identifiable {
        case system
        case arabic
        case german
        case english
        case spanish
        case french
        case indonesian
        case italian
        case korean
        case dutch
        case polish
        case portuguese
        case russian
        case swedish
        case turkish
        case ukrainian

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
            case .korean: "한국어"
            case .polish: "Polski"
            case .portuguese: "Português"
            case .russian: "Русский"
            case .spanish: "Español"
            case .swedish: "Svenska"
            case .turkish: "Türkçe"
            case .ukrainian: "Українська"
            }
        }

        /// The language code for bundle lookup, or `nil` for the system default.
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
            case .korean: "ko"
            case .polish: "pl"
            case .portuguese: "pt"
            case .russian: "ru"
            case .spanish: "es"
            case .swedish: "sv"
            case .turkish: "tr"
            case .ukrainian: "uk"
            }
        }

        /// The language code for YouTube Music API requests (`hl` parameter).
        /// Returns the explicit language code or derives one from the system locale,
        /// falling back to `"en"`.
        var apiLanguageCode: String {
            self.languageCode ?? Locale.current.language.languageCode?.identifier ?? "en"
        }

        /// The locale matching this language selection.
        var locale: Locale {
            if let code = self.languageCode {
                Locale(identifier: code)
            } else {
                Locale.current
            }
        }
    }

    // MARK: - Media Control Style

    /// Controls which buttons appear in the Now Playing widget (Control Center).
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

    // MARK: - Playback Audio Quality

    /// Preferred audio quality for playback through the YouTube Music WebView.
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

    // MARK: - Settings Properties

    /// The active content source (YouTube Music or regular YouTube).
    var appSource: AppSource {
        didSet {
            UserDefaults.standard.set(self.appSource.rawValue, forKey: Keys.appSource)
        }
    }

    /// Whether to show system notifications when the track changes.
    var showNowPlayingNotifications: Bool {
        didSet {
            UserDefaults.standard.set(self.showNowPlayingNotifications, forKey: Keys.showNowPlayingNotifications)
        }
    }

    /// The default page to show when the app launches.
    var defaultLaunchPage: LaunchPage {
        didSet {
            UserDefaults.standard.set(self.defaultLaunchPage.rawValue, forKey: Keys.defaultLaunchPage)
        }
    }

    /// Whether haptic feedback is enabled.
    var hapticFeedbackEnabled: Bool {
        didSet {
            UserDefaults.standard.set(self.hapticFeedbackEnabled, forKey: Keys.hapticFeedbackEnabled)
        }
    }

    /// Whether to remember shuffle/repeat settings across app restarts.
    var rememberPlaybackSettings: Bool {
        didSet {
            UserDefaults.standard.set(self.rememberPlaybackSettings, forKey: Keys.rememberPlaybackSettings)
            // Clear stale values when setting is disabled to prevent unexpected restoration
            if !self.rememberPlaybackSettings {
                UserDefaults.standard.removeObject(forKey: "playerShuffleEnabled")
                UserDefaults.standard.removeObject(forKey: "playerShuffleMode")
                UserDefaults.standard.removeObject(forKey: "playerRepeatMode")
            }
        }
    }

    /// Which buttons to show in the Now Playing widget: skip forward/backward or next/previous track.
    var mediaControlStyle: MediaControlStyle {
        didSet {
            UserDefaults.standard.set(self.mediaControlStyle.rawValue, forKey: Keys.mediaControlStyle)
        }
    }

    /// Preferred audio quality for playback through the YouTube Music WebView.
    var playbackAudioQuality: PlaybackAudioQuality {
        didSet {
            UserDefaults.standard.set(self.playbackAudioQuality.rawValue, forKey: Keys.playbackAudioQuality)
        }
    }

    /// Per-service enabled flags stored as a dictionary.
    private var enabledServices: [String: Bool] {
        didSet {
            UserDefaults.standard.set(self.enabledServices, forKey: Keys.enabledServices)
        }
    }

    /// Whether a specific scrobbling service is enabled by name.
    func isServiceEnabled(_ serviceName: String) -> Bool {
        self.enabledServices[serviceName] ?? false
    }

    /// Sets the enabled state for a specific scrobbling service by name.
    func setServiceEnabled(_ serviceName: String, _ enabled: Bool) {
        self.enabledServices[serviceName] = enabled
    }

    /// Whether Last.fm scrobbling is enabled (backward-compatible convenience).
    var lastFMEnabled: Bool {
        get { self.isServiceEnabled("Last.fm") }
        set { self.setServiceEnabled("Last.fm", newValue) }
    }

    /// Percentage of track duration required before scrobbling (0.0–1.0).
    var scrobblePercentThreshold: Double {
        didSet {
            UserDefaults.standard.set(self.scrobblePercentThreshold, forKey: Keys.scrobblePercentThreshold)
        }
    }

    /// Minimum seconds of play time before scrobbling (overrides percentage for long tracks).
    var scrobbleMinSeconds: TimeInterval {
        didSet {
            UserDefaults.standard.set(self.scrobbleMinSeconds, forKey: Keys.scrobbleMinSeconds)
        }
    }

    /// The last page the user was on (for "Last Used" option).
    var lastUsedPage: LaunchPage = .home

    /// Whether synced lyrics are preferred.
    var syncedLyricsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(self.syncedLyricsEnabled, forKey: Keys.syncedLyricsEnabled)
        }
    }

    /// Whether romanization of non-Latin lyrics is enabled.
    var romanizationEnabled: Bool {
        didSet {
            UserDefaults.standard.set(self.romanizationEnabled, forKey: Keys.romanizationEnabled)
        }
    }

    /// Whether the mini player floats above other windows.
    var keepMiniPlayerOnTop: Bool {
        didSet {
            UserDefaults.standard.set(self.keepMiniPlayerOnTop, forKey: Keys.keepMiniPlayerOnTop)
        }
    }

    // MARK: - Smart Shuffle defaults & ranges (single source of truth)

    /// Default cadence: insert a burst of suggestions every N originals.
    static let smartShuffleSuggestEveryNDefault = 3
    /// Valid range for the insert-every-N cadence.
    static let smartShuffleSuggestEveryNRange = 1 ... 6
    /// Default number of suggestions inserted at each slot.
    static let smartShuffleBurstDefault = 1
    /// Valid range for the per-insertion burst.
    static let smartShuffleBurstRange = 1 ... 5
    /// Default number of suggestions to keep queued ahead of the current track.
    static let smartShuffleSuggestionsAheadDefault = 20
    /// Valid range for how many suggestions to keep queued ahead.
    static let smartShuffleSuggestionsAheadRange = 5 ... 100

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Whether Smart Shuffle (the third shuffle state) is available from the shuffle button.
    var smartShuffleEnabled: Bool {
        didSet {
            UserDefaults.standard.set(self.smartShuffleEnabled, forKey: Keys.smartShuffleEnabled)
        }
    }

    /// Smart Shuffle interleave cadence: insert a burst of suggestions every N songs (1...6).
    var smartShuffleSuggestEveryN: Int {
        didSet {
            let clamped = Self.clamp(self.smartShuffleSuggestEveryN, to: Self.smartShuffleSuggestEveryNRange)
            if clamped != self.smartShuffleSuggestEveryN {
                self.smartShuffleSuggestEveryN = clamped
            }
            UserDefaults.standard.set(clamped, forKey: Keys.smartShuffleSuggestEveryN)
        }
    }

    /// Smart Shuffle burst: how many suggestions to insert at each slot (1...5).
    var smartShuffleBurst: Int {
        didSet {
            let clamped = Self.clamp(self.smartShuffleBurst, to: Self.smartShuffleBurstRange)
            if clamped != self.smartShuffleBurst {
                self.smartShuffleBurst = clamped
            }
            UserDefaults.standard.set(clamped, forKey: Keys.smartShuffleBurst)
        }
    }

    /// Smart Shuffle: how many suggestions to keep queued ahead of the current track (5...100).
    var smartShuffleSuggestionsAhead: Int {
        didSet {
            let clamped = Self.clamp(self.smartShuffleSuggestionsAhead, to: Self.smartShuffleSuggestionsAheadRange)
            if clamped != self.smartShuffleSuggestionsAhead {
                self.smartShuffleSuggestionsAhead = clamped
            }
            UserDefaults.standard.set(clamped, forKey: Keys.smartShuffleSuggestionsAhead)
        }
    }

    /// Whether the ambient color backdrop is shown on the YouTube watch page.
    /// Applies to regular YouTube videos only, not the Music experience.
    var ambientBackdropEnabled: Bool {
        didSet {
            UserDefaults.standard.set(self.ambientBackdropEnabled, forKey: Keys.ambientBackdropEnabled)
        }
    }

    /// The chosen ambient backdrop style when the feature is enabled.
    var ambientBackdropStyle: AmbientBackdropStyle {
        didSet {
            UserDefaults.standard.set(self.ambientBackdropStyle.rawValue, forKey: Keys.ambientBackdropStyle)
        }
    }

    /// Whether a playing YouTube video pops out into the floating window when
    /// the user navigates away from the inline watch view. When disabled,
    /// playback stops instead. Applies to regular YouTube videos only, not the
    /// Music experience.
    var popOutVideoOnNavigateAway: Bool {
        didSet {
            UserDefaults.standard.set(self.popOutVideoOnNavigateAway, forKey: Keys.popOutVideoOnNavigateAway)
        }
    }

    /// The style the YouTube watch page should request: the chosen style when
    /// enabled, `.off` when the feature is disabled. Runtime energy/accessibility
    /// downgrades are applied inside `AmbientVideoBackdrop`, which observes those
    /// external states directly.
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

    /// The language used for the app interface and API content.
    var contentLanguage: ContentLanguage {
        didSet {
            UserDefaults.standard.set(self.contentLanguage.rawValue, forKey: Keys.contentLanguage)
            AppLocalization.setLanguage(self.contentLanguage.languageCode)
            APICache.shared.invalidateAll()
        }
    }

    #if DEBUG
        /// Debug-only switch that forces the app to render macOS 15 fallback UI on newer OS versions.
        var useLegacyMacOS15UI: Bool {
            didSet {
                UserDefaults.standard.set(self.useLegacyMacOS15UI, forKey: Keys.useLegacyMacOS15UI)
            }
        }
    #else
        /// Release builds always use the native UI for the host OS.
        let useLegacyMacOS15UI = false
    #endif

    // MARK: - Initialization

    private init() {
        // Load persisted settings or use defaults
        self.showNowPlayingNotifications = UserDefaults.standard.object(forKey: Keys.showNowPlayingNotifications) as? Bool ?? true
        self.hapticFeedbackEnabled = UserDefaults.standard.object(forKey: Keys.hapticFeedbackEnabled) as? Bool ?? true
        self.rememberPlaybackSettings = UserDefaults.standard.object(forKey: Keys.rememberPlaybackSettings) as? Bool ?? false

        // Load per-service enabled flags, migrating from legacy lastFMEnabled if needed
        if let stored = UserDefaults.standard.dictionary(forKey: Keys.enabledServices) as? [String: Bool] {
            self.enabledServices = stored
        } else if let legacyEnabled = UserDefaults.standard.object(forKey: Keys.lastFMEnabled) as? Bool {
            // Migrate from single-service flag to dictionary
            self.enabledServices = ["Last.fm": legacyEnabled]
        } else {
            self.enabledServices = [:]
        }
        self.scrobblePercentThreshold = UserDefaults.standard.object(forKey: Keys.scrobblePercentThreshold) as? Double ?? 0.5
        self.scrobbleMinSeconds = UserDefaults.standard.object(forKey: Keys.scrobbleMinSeconds) as? Double ?? 240
        self.syncedLyricsEnabled = UserDefaults.standard.object(forKey: Keys.syncedLyricsEnabled) as? Bool ?? true
        self.romanizationEnabled = UserDefaults.standard.object(forKey: Keys.romanizationEnabled) as? Bool ?? true
        self.keepMiniPlayerOnTop = UserDefaults.standard.object(forKey: Keys.keepMiniPlayerOnTop) as? Bool ?? false
        self.smartShuffleEnabled = UserDefaults.standard.object(forKey: Keys.smartShuffleEnabled) as? Bool ?? true
        // Property observers do not fire for assignments in init, so clamp persisted values here too.
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

        if let rawValue = UserDefaults.standard.string(forKey: Keys.appSource),
           let source = AppSource(rawValue: rawValue)
        {
            self.appSource = source
        } else {
            self.appSource = .music
        }

        AppLocalization.setLanguage(self.contentLanguage.languageCode)

        // Persist migration from legacy lastFMEnabled key (must run after all properties initialized)
        if UserDefaults.standard.object(forKey: Keys.enabledServices) == nil,
           UserDefaults.standard.object(forKey: Keys.lastFMEnabled) != nil
        {
            UserDefaults.standard.set(self.enabledServices, forKey: Keys.enabledServices)
            UserDefaults.standard.removeObject(forKey: Keys.lastFMEnabled)
        }
    }

    // MARK: - Computed Properties

    /// Returns the page to navigate to on launch based on settings.
    var launchPage: LaunchPage {
        switch self.defaultLaunchPage {
        case .lastUsed:
            self.lastUsedPage
        default:
            self.defaultLaunchPage
        }
    }

    /// Returns the NavigationItem to use on app launch.
    var launchNavigationItem: NavigationItem {
        self.launchPage.navigationItem
    }
}
