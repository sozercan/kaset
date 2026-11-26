import Foundation

enum UITestConfig {
    static let uiTestModeArgument = "-UITestMode"

    static let skipAuthArgument = "-SkipAuth"

    static let mockHomeSectionsKey = "MOCK_HOME_SECTIONS"

    static let mockSearchResultsKey = "MOCK_SEARCH_RESULTS"

    static let mockPlaylistsKey = "MOCK_PLAYLISTS"

    static let mockCurrentTrackKey = "MOCK_CURRENT_TRACK"

    static let mockIsPlayingKey = "MOCK_IS_PLAYING"

    static let mockHasVideoKey = "MOCK_HAS_VIDEO"

    static let mockFavoritesKey = "MOCK_FAVORITES"

    static let mockAccountsKey = "MOCK_ACCOUNTS"

    static let mockAccountSwitchFailKey = "MOCK_ACCOUNT_SWITCH_FAIL"

    static let mockAccountLoadingDelayKey = "MOCK_ACCOUNT_LOADING_DELAY"

    static let mockLoggedOutKey = "MOCK_LOGGED_OUT"

    static let mockAskGeminiEnabledKey = "MOCK_ASK_GEMINI_ENABLED"

    static let mockPodcastsRegionUnavailableKey = "MOCK_PODCASTS_REGION_UNAVAILABLE"

    static var isUITestMode: Bool {
        CommandLine.arguments.contains(uiTestModeArgument)
            || ProcessInfo.processInfo.environment["UI_TEST_MODE"] == "1"
    }

    static var isRunningUnitTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || NSClassFromString("Testing.Test") != nil
            || NSClassFromString("_Testing.Case") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || Bundle.main.bundleURL.path.contains("Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents")
            || Bundle.main.bundleURL.path.hasSuffix(".xctest")
            || ProcessInfo.processInfo.environment["SWIFT_TESTING_ENABLED"] == "1"
    }

    static var shouldSkipAuth: Bool {
        CommandLine.arguments.contains(skipAuthArgument)
            || ProcessInfo.processInfo.environment["SKIP_AUTH"] == "1"
    }

    static func environmentValue(for key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }
}
