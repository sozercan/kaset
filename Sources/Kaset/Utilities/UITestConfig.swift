import Foundation
import Synchronization

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
        let explicitOverride: Bool
        #if DEBUG
            explicitOverride = self.explicitUnitTestHostOverride
        #else
            explicitOverride = false
        #endif
        return Self.detectUnitTestHost(
            environment: ProcessInfo.processInfo.environment,
            hasXCTestCaseClass: NSClassFromString("XCTestCase") != nil,
            explicitOverride: explicitOverride
        )
    }

    static func detectUnitTestHost(
        environment: [String: String],
        hasXCTestCaseClass: Bool,
        explicitOverride: Bool = false
    ) -> Bool {
        if explicitOverride {
            return true
        }
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["SWIFT_TESTING_ENABLED"] == "1"
            || environment["KASET_UNIT_TEST_HOST"] == "1"
            || hasXCTestCaseClass
    }

    #if DEBUG
        private static let explicitUnitTestHostOverrideStorage = Atomic<Bool>(false)

        static var explicitUnitTestHostOverride: Bool {
            get {
                self.explicitUnitTestHostOverrideStorage.load(ordering: .acquiring)
            }
            set {
                self.explicitUnitTestHostOverrideStorage.store(newValue, ordering: .releasing)
            }
        }
    #endif

    static var shouldSkipAuth: Bool {
        CommandLine.arguments.contains(skipAuthArgument)
            || ProcessInfo.processInfo.environment["SKIP_AUTH"] == "1"
    }

    static func environmentValue(for key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }
}
