import AppKit
@preconcurrency import XCTest

// MARK: - TestAccessibilityID

/// Accessibility identifiers matching those in AccessibilityID enum.
/// Duplicated here to avoid import issues with the app target.
enum TestAccessibilityID {
    enum Sidebar {
        static let container = "sidebar"
        static let searchItem = "sidebar.search"
        static let homeItem = "sidebar.home"
        static let exploreItem = "sidebar.explore"
        static let likedMusicItem = "sidebar.likedMusic"
        static let libraryItem = "sidebar.library"
    }

    enum Home {
        static let container = "homeView"
        static let scrollView = "homeView.scrollView"
    }

    enum Search {
        static let searchField = "searchView.searchField"
        static let clearButton = "searchView.clearButton"
        static let suggestionsContainer = "searchView.suggestions"

        static func suggestion(index: Int) -> String {
            "searchView.suggestion.\(index)"
        }

        static func resultRow(index: Int) -> String {
            "searchView.result.\(index)"
        }
    }

    enum SearchOverlay {
        static let backdrop = "searchOverlay.backdrop"
        static let window = "searchOverlay.window"
        static let input = "searchOverlay.input"
        static let returnHint = "searchOverlay.returnHint"
        static let historyList = "searchOverlay.historyList"

        static func historyRow(index: Int) -> String {
            "searchOverlay.history.\(index)"
        }

        static func removeHistoryButton(index: Int) -> String {
            "searchOverlay.removeHistoryButton.\(index)"
        }
    }

    enum MainWindow {
        static let container = "mainWindow"
        static let commandBar = "mainWindow.commandBar"
        static let commandBarOverlay = "mainWindow.commandBarOverlay"
        static let commandBarInput = "mainWindow.commandBarInput"
    }

    enum PlayerBar {
        static let miniPlayerButton = "playerBar.miniPlayer"
        static let videoButton = "playerBar.video"
    }

    enum VideoWindow {
        static let container = "videoWindow"
    }

    enum Lyrics {
        static let fallbackPanel = "lyrics.fallbackPanel"
    }

    // MARK: - Sidebar Profile

    enum SidebarProfile {
        static let container = "sidebarProfile"
        static let profileButton = "sidebarProfile.profileButton"
        static let loadingState = "sidebarProfile.loading"
        static let loggedOutState = "sidebarProfile.loggedOut"
    }

    // MARK: - Account Switcher

    enum AccountSwitcher {
        static let container = "accountSwitcher"
        static let header = "accountSwitcher.header"
        static let accountsList = "accountSwitcher.accountsList"
        static let guestModeRow = "accountSwitcher.guestMode"

        static func accountRow(index: Int) -> String {
            "accountSwitcher.account.\(index)"
        }
    }
}

// MARK: - MockFavoriteItem

/// Helper type for creating mock favorites in UI tests.
struct MockFavoriteItem {
    let id: String
    let pinnedAt: Date
    let type: MockFavoriteType

    enum MockFavoriteType {
        case song(videoId: String, title: String, artist: String)
        case album(id: String, title: String, artist: String)
        case playlist(id: String, title: String, author: String)
        case artist(id: String, name: String)
    }

    init(id: String = UUID().uuidString, pinnedAt: Date = Date(), type: MockFavoriteType) {
        self.id = id
        self.pinnedAt = pinnedAt
        self.type = type
    }

    /// Creates a mock song favorite.
    static func song(videoId: String, title: String, artist: String) -> MockFavoriteItem {
        MockFavoriteItem(type: .song(videoId: videoId, title: title, artist: artist))
    }

    /// Creates a mock album favorite.
    static func album(id: String, title: String, artist: String) -> MockFavoriteItem {
        MockFavoriteItem(type: .album(id: id, title: title, artist: artist))
    }

    /// Creates a mock playlist favorite.
    static func playlist(id: String, title: String, author: String) -> MockFavoriteItem {
        MockFavoriteItem(type: .playlist(id: id, title: title, author: author))
    }

    /// Creates a mock artist favorite.
    static func artist(id: String, name: String) -> MockFavoriteItem {
        MockFavoriteItem(type: .artist(id: id, name: name))
    }
}

// MARK: - KasetUITestCase

/// Base class for Kaset UI tests.
/// Provides common setup, launch configuration, and helper methods.
class KasetUITestCase: XCTestCase {
    private static let appBundleIdentifier = "com.sertacozercan.Kaset"

    /// The application under test.
    var app: XCUIApplication!

    // MARK: - Setup / Teardown

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Stop immediately when a failure occurs
        continueAfterFailure = false

        // Create new app instance. Prefer the freshly-built local app bundle;
        // fall back to /Applications only when the local bundle is unavailable.
        let explicitAppPath = ProcessInfo.processInfo.environment["KASET_UI_TEST_APP_PATH"]
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let localBuildPath = repositoryRoot
            .appendingPathComponent(".build/app/Kaset.app")
            .path
        let preferredAppPath = explicitAppPath ?? localBuildPath
        let appURL = FileManager.default.fileExists(atPath: preferredAppPath)
            ? URL(fileURLWithPath: preferredAppPath)
            : URL(fileURLWithPath: "/Applications/Kaset.app")
        Self.terminateRunningKaset()

        let bundleIdentifier = Self.appBundleIdentifier
        let configuredApp = MainActor.assumeIsolated {
            let application = if FileManager.default.fileExists(atPath: appURL.path) {
                XCUIApplication(url: appURL)
            } else {
                XCUIApplication(bundleIdentifier: bundleIdentifier)
            }

            // Add UI test mode arguments
            application.launchArguments.append("-UITestMode")
            application.launchArguments.append("-SkipAuth")

            // Also set via environment (more reliable with XCUIApplication(url:))
            application.launchEnvironment["UI_TEST_MODE"] = "1"
            application.launchEnvironment["SKIP_AUTH"] = "1"

            // Disable animations for faster, more reliable tests
            application.launchArguments.append("-UIAnimationsDisabled")

            return application
        }
        self.app = configuredApp
    }

    override func tearDownWithError() throws {
        let application = self.app
        self.app = nil
        MainActor.assumeIsolated {
            application?.terminate()
        }
        try super.tearDownWithError()
    }

    private static func terminateRunningKaset() {
        for runningApp in NSRunningApplication.runningApplications(withBundleIdentifier: self.appBundleIdentifier) {
            runningApp.terminate()
            let deadline = Date().addingTimeInterval(3)
            while !runningApp.isTerminated, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            if !runningApp.isTerminated {
                runningApp.forceTerminate()
            }
        }
    }

    // MARK: - Launch Helpers

    /// Launches the app with mock home sections.
    @MainActor
    func launchWithMockHome(sectionCount: Int = 3, itemsPerSection: Int = 5) {
        let sections = (0 ..< sectionCount).map { sectionIndex in
            [
                "id": "section-\(sectionIndex)",
                "title": "Test Section \(sectionIndex)",
                "items": (0 ..< itemsPerSection).map { itemIndex in
                    [
                        "type": "song",
                        "id": "song-\(sectionIndex)-\(itemIndex)",
                        "title": "Song \(itemIndex)",
                        "artist": "Artist \(itemIndex)",
                        "videoId": "video-\(sectionIndex)-\(itemIndex)",
                    ]
                },
            ]
        }

        if let jsonData = try? JSONSerialization.data(withJSONObject: sections),
           let jsonString = String(data: jsonData, encoding: .utf8)
        {
            self.app.launchEnvironment["MOCK_HOME_SECTIONS"] = jsonString
        }

        self.app.launch()
    }

    /// Launches the app with mock search results.
    @MainActor
    func launchWithMockSearch(songCount: Int = 5) {
        let songs = (0 ..< songCount).map { index in
            [
                "id": "search-song-\(index)",
                "title": "Search Result \(index)",
                "artist": "Search Artist \(index)",
                "videoId": "search-video-\(index)",
            ]
        }

        if let jsonData = try? JSONSerialization.data(withJSONObject: ["songs": songs]),
           let jsonString = String(data: jsonData, encoding: .utf8)
        {
            self.app.launchEnvironment["MOCK_SEARCH_RESULTS"] = jsonString
        }

        self.app.launch()
    }

    /// Launches the app with mock library playlists.
    @MainActor
    func launchWithMockLibrary(playlistCount: Int = 3) {
        let playlists = (0 ..< playlistCount).map { index in
            [
                "id": "playlist-\(index)",
                "title": "Playlist \(index)",
                "trackCount": 10 + index,
            ]
        }

        if let jsonData = try? JSONSerialization.data(withJSONObject: playlists),
           let jsonString = String(data: jsonData, encoding: .utf8)
        {
            self.app.launchEnvironment["MOCK_PLAYLISTS"] = jsonString
        }

        self.app.launch()
    }

    /// Launches the app with a mock current track (player has something playing).
    @MainActor
    func launchWithMockPlayer(isPlaying: Bool = true, hasVideo: Bool = false) {
        let track: [String: Any] = [
            "id": "current-track",
            "title": "Now Playing Song",
            "artist": "Current Artist",
            "videoId": "current-video",
            "duration": 180,
            "hasVideo": hasVideo,
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: track),
           let jsonString = String(data: jsonData, encoding: .utf8)
        {
            self.app.launchEnvironment["MOCK_CURRENT_TRACK"] = jsonString
        }
        self.app.launchEnvironment["MOCK_IS_PLAYING"] = isPlaying ? "true" : "false"
        self.app.launchEnvironment["MOCK_HAS_VIDEO"] = hasVideo ? "true" : "false"

        self.app.launch()
    }

    /// Launches the app with a mock current track that has video available.
    @MainActor
    func launchWithMockPlayerWithVideo(isPlaying: Bool = true) {
        self.launchWithMockPlayer(isPlaying: isPlaying, hasVideo: true)
    }

    /// Launches the app with mock favorites.
    /// - Parameter items: Array of favorite item configurations.
    @MainActor
    func launchWithMockFavorites(_ items: [MockFavoriteItem]) {
        let favorites = items.map { item -> [String: Any] in
            var dict: [String: Any] = [
                "id": item.id,
                "pinnedAt": ISO8601DateFormatter().string(from: item.pinnedAt),
            ]

            // Encode the itemType based on type
            switch item.type {
            case let .song(videoId, title, artist):
                dict["itemType"] = [
                    "song": [
                        "_0": [
                            "id": videoId,
                            "title": title,
                            "artists": [["id": "artist-\(videoId)", "name": artist]],
                            "videoId": videoId,
                        ],
                    ],
                ]
            case let .album(albumId, title, artist):
                dict["itemType"] = [
                    "album": [
                        "_0": [
                            "id": albumId,
                            "title": title,
                            "artists": [["id": "artist-\(albumId)", "name": artist]],
                        ],
                    ],
                ]
            case let .playlist(playlistId, title, author):
                dict["itemType"] = [
                    "playlist": [
                        "_0": [
                            "id": playlistId,
                            "title": title,
                            "author": author,
                        ],
                    ],
                ]
            case let .artist(artistId, name):
                dict["itemType"] = [
                    "artist": [
                        "_0": [
                            "id": artistId,
                            "name": name,
                        ],
                    ],
                ]
            }

            return dict
        }

        if let jsonData = try? JSONSerialization.data(withJSONObject: favorites),
           let jsonString = String(data: jsonData, encoding: .utf8)
        {
            self.app.launchEnvironment["MOCK_FAVORITES"] = jsonString
        }

        self.app.launch()
    }

    /// Launches the app with mock player state and mock favorites.
    @MainActor
    func launchWithMockPlayerAndFavorites(
        isPlaying: Bool = true,
        hasVideo: Bool = false,
        favorites: [MockFavoriteItem] = []
    ) {
        let track: [String: Any] = [
            "id": "current-track",
            "title": "Now Playing Song",
            "artist": "Current Artist",
            "videoId": "current-video",
            "duration": 180,
            "hasVideo": hasVideo,
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: track),
           let jsonString = String(data: jsonData, encoding: .utf8)
        {
            self.app.launchEnvironment["MOCK_CURRENT_TRACK"] = jsonString
        }
        self.app.launchEnvironment["MOCK_IS_PLAYING"] = isPlaying ? "true" : "false"
        self.app.launchEnvironment["MOCK_HAS_VIDEO"] = hasVideo ? "true" : "false"

        // Add mock favorites
        let favoritesArray = favorites.map { item -> [String: Any] in
            var dict: [String: Any] = [
                "id": item.id,
                "pinnedAt": ISO8601DateFormatter().string(from: item.pinnedAt),
            ]

            switch item.type {
            case let .song(videoId, title, artist):
                dict["itemType"] = [
                    "song": [
                        "_0": [
                            "id": videoId,
                            "title": title,
                            "artists": [["id": "artist-\(videoId)", "name": artist]],
                            "videoId": videoId,
                        ],
                    ],
                ]
            case let .album(albumId, title, artist):
                dict["itemType"] = [
                    "album": [
                        "_0": [
                            "id": albumId,
                            "title": title,
                            "artists": [["id": "artist-\(albumId)", "name": artist]],
                        ],
                    ],
                ]
            case let .playlist(playlistId, title, author):
                dict["itemType"] = [
                    "playlist": [
                        "_0": [
                            "id": playlistId,
                            "title": title,
                            "author": author,
                        ],
                    ],
                ]
            case let .artist(artistId, name):
                dict["itemType"] = [
                    "artist": [
                        "_0": [
                            "id": artistId,
                            "name": name,
                        ],
                    ],
                ]
            }

            return dict
        }

        if let jsonData = try? JSONSerialization.data(withJSONObject: favoritesArray),
           let jsonString = String(data: jsonData, encoding: .utf8)
        {
            self.app.launchEnvironment["MOCK_FAVORITES"] = jsonString
        }

        self.app.launch()
    }

    /// Launches the app with default configuration (logged in, no specific mock data).
    @MainActor
    func launchDefault() {
        self.app.launch()
    }

    // MARK: - Wait Helpers

    /// Waits for an element to exist with a timeout.
    @discardableResult
    @MainActor
    func waitForElement(
        _ element: XCUIElement,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let predicate = NSPredicate(format: "exists == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)

        if result != .completed {
            XCTFail("Timed out waiting for element: \(element)", file: file, line: line)
            return false
        }
        return true
    }

    /// Waits for an element to be hittable (visible and interactable).
    @discardableResult
    @MainActor
    func waitForHittable(
        _ element: XCUIElement,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let predicate = NSPredicate(format: "isHittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)

        if result != .completed {
            XCTFail("Timed out waiting for element to be hittable: \(element)", file: file, line: line)
            return false
        }
        return true
    }

    /// Waits for element count to match expected value.
    @discardableResult
    @MainActor
    func waitForElementCount(
        _ query: XCUIElementQuery,
        count: Int,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let predicate = NSPredicate(format: "count == \(count)")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: query)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)

        if result != .completed {
            XCTFail(
                "Timed out waiting for element count. Expected: \(count), Actual: \(query.count)",
                file: file,
                line: line
            )
            return false
        }
        return true
    }

    /// Waits for an element to disappear with a timeout.
    @discardableResult
    @MainActor
    func waitForElementToDisappear(
        _ element: XCUIElement,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)

        if result != .completed {
            XCTFail("Timed out waiting for element to disappear: \(element)", file: file, line: line)
            return false
        }
        return true
    }

    // MARK: - Navigation Helpers

    /// Navigates to a sidebar item by accessibility identifier.
    @MainActor
    func navigateToSidebarItem(_ accessibilityID: String) {
        // Find by accessibility identifier first, fall back to label
        var sidebarItem = self.app.buttons[accessibilityID].firstMatch
        if !sidebarItem.exists {
            // Try other element types
            sidebarItem = self.app.cells[accessibilityID].firstMatch
        }

        // First wait for element to exist
        let existsPredicate = NSPredicate(format: "exists == true")
        let existsExpectation = XCTNSPredicateExpectation(predicate: existsPredicate, object: sidebarItem)
        let existsResult = XCTWaiter().wait(for: [existsExpectation], timeout: 15)

        guard existsResult == .completed else {
            XCTFail("Sidebar item '\(accessibilityID)' never appeared")
            return
        }

        // Then wait for it to be hittable (may need time for layout)
        if self.waitForHittable(sidebarItem, timeout: 10) {
            sidebarItem.click()
        }
    }

    /// Navigates to a sidebar item by label text.
    @MainActor
    func navigateToSidebarItemByLabel(_ label: String) {
        // Wait for sidebar to be ready with extended timeout for UI test startup
        let sidebarItem = self.app.staticTexts[label].firstMatch

        // First wait for element to exist
        let existsPredicate = NSPredicate(format: "exists == true")
        let existsExpectation = XCTNSPredicateExpectation(predicate: existsPredicate, object: sidebarItem)
        let existsResult = XCTWaiter().wait(for: [existsExpectation], timeout: 15)

        guard existsResult == .completed else {
            XCTFail("Sidebar item '\(label)' never appeared")
            return
        }

        // Then wait for it to be hittable (may need time for layout)
        if self.waitForHittable(sidebarItem, timeout: 10) {
            sidebarItem.click()
        }
    }

    /// Navigates to Home via sidebar.
    @MainActor
    func navigateToHome() {
        self.navigateToSidebarItem(TestAccessibilityID.Sidebar.homeItem)
    }

    /// Navigates to Search via sidebar.
    @MainActor
    func navigateToSearch() {
        self.navigateToSidebarItem(TestAccessibilityID.Sidebar.searchItem)
    }

    /// Navigates to Explore via sidebar.
    @MainActor
    func navigateToExplore() {
        self.navigateToSidebarItem(TestAccessibilityID.Sidebar.exploreItem)
    }

    /// Navigates to Library via sidebar.
    @MainActor
    func navigateToLibrary() {
        self.navigateToSidebarItem(TestAccessibilityID.Sidebar.libraryItem)
    }

    /// Navigates to Liked Music via sidebar.
    @MainActor
    func navigateToLikedMusic() {
        self.navigateToSidebarItem(TestAccessibilityID.Sidebar.likedMusicItem)
    }
}
