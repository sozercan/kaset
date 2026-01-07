import Foundation

/// Launch arguments and environment keys for UI testing.
/// Use these to configure the app in test mode with mock data.
enum UITestConfig {
    // MARK: - Launch Arguments

    /// When present, app runs in UI test mode with mock services.
    static let uiTestModeArgument = "-UITestMode"

    /// When present, skip onboarding and assume logged in.
    static let skipAuthArgument = "-SkipAuth"

    // MARK: - Environment Keys

    /// JSON-encoded mock home sections data.
    static let mockHomeSectionsKey = "MOCK_HOME_SECTIONS"

    /// JSON-encoded mock search results data.
    static let mockSearchResultsKey = "MOCK_SEARCH_RESULTS"

    /// JSON-encoded mock playlists data.
    static let mockPlaylistsKey = "MOCK_PLAYLISTS"

    /// JSON-encoded mock current track data.
    static let mockCurrentTrackKey = "MOCK_CURRENT_TRACK"

    /// Whether player should simulate playing state.
    static let mockIsPlayingKey = "MOCK_IS_PLAYING"

    /// Whether the current track has video available.
    static let mockHasVideoKey = "MOCK_HAS_VIDEO"

    /// JSON-encoded mock favorites data.
    static let mockFavoritesKey = "MOCK_FAVORITES"

    // MARK: - Detection

    /// Returns true if the app was launched in UI test mode.
    static var isUITestMode: Bool {
        CommandLine.arguments.contains(uiTestModeArgument)
    }

    /// Returns true if running inside XCTest (unit tests).
    /// Checks for XCTestCase class presence at runtime.
    static var isRunningUnitTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    /// Returns true if auth should be skipped (simulate logged in).
    static var shouldSkipAuth: Bool {
        CommandLine.arguments.contains(skipAuthArgument)
    }

    /// Returns environment value for given key.
    static func environmentValue(for key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }
}
