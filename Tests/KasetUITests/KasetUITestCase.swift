@preconcurrency import XCTest

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

    enum MainWindow {
        static let container = "mainWindow"
        static let commandBarInput = "mainWindow.commandBarInput"
    }

    enum PlayerBar {
        static let miniPlayerButton = "playerBar.miniPlayer"
        static let videoButton = "playerBar.video"
        static let volumeSlider = "playerBar.volumeSlider"
    }

    enum VideoWindow {
        static let container = "videoWindow"
    }

    enum Lyrics {
        static let panel = "lyrics.panel"
        static let fallbackPanel = "lyrics.fallbackPanel"
    }

    enum SidebarProfile {
        static let container = "sidebarProfile"
        static let profileButton = "sidebarProfile.profileButton"
        static let loadingState = "sidebarProfile.loading"
        static let loggedOutState = "sidebarProfile.loggedOut"
    }

    enum AccountSwitcher {
        static let container = "accountSwitcher"
        static let header = "accountSwitcher.header"
        static let accountsList = "accountSwitcher.accountsList"
        static let guestModeRow = "accountSwitcher.guestMode"
        static let signOutButton = "accountSwitcher.signOut"

        static func accountRow(index: Int) -> String {
            "accountSwitcher.account.\(index)"
        }
    }
}

@MainActor
class KasetUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()

        continueAfterFailure = false

        let appURL = URL(fileURLWithPath: "/Applications/Kaset.app")
        if FileManager.default.fileExists(atPath: appURL.path) {
            self.app = XCUIApplication(url: appURL)
        } else {
            self.app = XCUIApplication(bundleIdentifier: "com.sertacozercan.Kaset")
        }

        self.app.launchArguments.append("-UITestMode")
        self.app.launchArguments.append("-SkipAuth")

        self.app.launchEnvironment["UI_TEST_MODE"] = "1"
        self.app.launchEnvironment["SKIP_AUTH"] = "1"

        self.app.launchArguments.append("-UIAnimationsDisabled")
    }

    override func tearDownWithError() throws {
        self.app = nil
        try super.tearDownWithError()
    }

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

    func launchWithMockSearch(songCount: Int = 5) {
        let songs = (0 ..< songCount).map { index in
            [
                "id": "search-song-\(index)",
                "title": "Search Result \(index)",
                "artist": "Search Artist \(index)",
                "videoId": "search-video-\(index)",
                "albumId": "MPREbSearchAlbum\(index)",
                "albumTitle": "Search Album \(index)",
            ]
        }

        if let jsonData = try? JSONSerialization.data(withJSONObject: ["songs": songs]),
           let jsonString = String(data: jsonData, encoding: .utf8)
        {
            self.app.launchEnvironment["MOCK_SEARCH_RESULTS"] = jsonString
        }

        self.app.launch()
    }

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

    func launchWithMockPlayerWithVideo(isPlaying: Bool = true) {
        self.launchWithMockPlayer(isPlaying: isPlaying, hasVideo: true)
    }

    func launchDefault() {
        self.app.launch()
    }

    @discardableResult
    func waitForElement(
        _ element: XCUIElement,
        timeout: TimeInterval = 5,
        file: StaticString = #file,
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

    @discardableResult
    func waitForHittable(
        _ element: XCUIElement,
        timeout: TimeInterval = 5,
        file: StaticString = #file,
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

    @discardableResult
    func waitForElementToDisappear(
        _ element: XCUIElement,
        timeout: TimeInterval = 5,
        file: StaticString = #file,
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

    func navigateToSidebarItem(_ accessibilityID: String) {
        var sidebarItem = self.app.buttons[accessibilityID].firstMatch
        if !sidebarItem.exists {
            sidebarItem = self.app.cells[accessibilityID].firstMatch
        }

        let existsPredicate = NSPredicate(format: "exists == true")
        let existsExpectation = XCTNSPredicateExpectation(predicate: existsPredicate, object: sidebarItem)
        let existsResult = XCTWaiter().wait(for: [existsExpectation], timeout: 15)

        guard existsResult == .completed else {
            XCTFail("Sidebar item '\(accessibilityID)' never appeared")
            return
        }

        if self.waitForHittable(sidebarItem, timeout: 10) {
            sidebarItem.click()
        }
    }

    func navigateToHome() {
        self.navigateToSidebarItem(TestAccessibilityID.Sidebar.homeItem)
    }

    func navigateToSearch() {
        self.navigateToSidebarItem(TestAccessibilityID.Sidebar.searchItem)
    }

    func navigateToExplore() {
        self.navigateToSidebarItem(TestAccessibilityID.Sidebar.exploreItem)
    }

    func navigateToLibrary() {
        self.navigateToSidebarItem(TestAccessibilityID.Sidebar.libraryItem)
    }

    func navigateToLikedMusic() {
        self.navigateToSidebarItem(TestAccessibilityID.Sidebar.likedMusicItem)
    }
}
