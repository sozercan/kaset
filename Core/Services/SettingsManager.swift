import Foundation
import Observation

/// Manages user preferences persisted via UserDefaults.
@MainActor
@Observable
final class SettingsManager {
    static let shared = SettingsManager()

    // MARK: - Settings Keys

    private enum Keys {
        static let showNowPlayingNotifications = "settings.showNowPlayingNotifications"
        static let defaultLaunchPage = "settings.defaultLaunchPage"
        static let hapticFeedbackEnabled = "settings.hapticFeedbackEnabled"
        static let rememberPlaybackSettings = "settings.rememberPlaybackSettings"
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

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .home: "Home"
            case .explore: "Explore"
            case .charts: "Charts"
            case .moodsAndGenres: "Moods & Genres"
            case .newReleases: "New Releases"
            case .likedMusic: "Liked Music"
            case .playlists: "Playlists"
            case .lastUsed: "Last Used"
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

    // MARK: - Settings Properties

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
                UserDefaults.standard.removeObject(forKey: "playerRepeatMode")
            }
        }
    }

    /// The last page the user was on (for "Last Used" option).
    var lastUsedPage: LaunchPage = .home

    // MARK: - Initialization

    private init() {
        // Load persisted settings or use defaults
        self.showNowPlayingNotifications = UserDefaults.standard.object(forKey: Keys.showNowPlayingNotifications) as? Bool ?? true
        self.hapticFeedbackEnabled = UserDefaults.standard.object(forKey: Keys.hapticFeedbackEnabled) as? Bool ?? true
        self.rememberPlaybackSettings = UserDefaults.standard.object(forKey: Keys.rememberPlaybackSettings) as? Bool ?? false

        if let rawValue = UserDefaults.standard.string(forKey: Keys.defaultLaunchPage),
           let page = LaunchPage(rawValue: rawValue)
        {
            self.defaultLaunchPage = page
        } else {
            self.defaultLaunchPage = .home
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
