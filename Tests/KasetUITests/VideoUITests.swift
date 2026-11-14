import XCTest

/// Video is an explicit secondary action on the unified floating-player control.
@MainActor
final class VideoUITests: KasetUITestCase {
    private var floatingPlayerButton: XCUIElement {
        app.buttons[TestAccessibilityID.PlayerBar.miniPlayerButton]
    }

    private var videoWindow: XCUIElement {
        app.windows.matching(NSPredicate(
            format: "identifier == %@ OR label == %@",
            TestAccessibilityID.VideoWindow.container,
            "Video"
        )).firstMatch
    }

    private func skipVideoWindowAssertionsOnMacOS15() throws {
        if #unavailable(macOS 26.0) {
            throw XCTSkip("Video window extraction is covered on macOS 26.")
        }
    }

    private func chooseVideoAction(_ title: String = "Video") {
        XCTAssertTrue(waitForHittable(self.floatingPlayerButton))
        self.floatingPlayerButton.rightClick()
        let item = app.menuItems[title]
        XCTAssertTrue(waitForElement(item))
        item.click()
    }

    func testUnifiedControlVisibleWithoutVideo() {
        launchWithMockPlayer(isPlaying: true, hasVideo: false)
        navigateToHome()

        XCTAssertTrue(waitForElement(self.floatingPlayerButton, timeout: 10))
        XCTAssertFalse(app.buttons[TestAccessibilityID.PlayerBar.videoButton].exists)
        self.floatingPlayerButton.rightClick()
        let item = app.menuItems["Video"]
        XCTAssertTrue(waitForElement(item))
        XCTAssertFalse(item.isEnabled)
    }

    func testUnifiedControlVisibleWithVideo() {
        launchWithMockPlayerWithVideo(isPlaying: true)
        navigateToHome()

        XCTAssertTrue(waitForHittable(self.floatingPlayerButton))
        XCTAssertFalse(app.buttons[TestAccessibilityID.PlayerBar.videoButton].exists)
    }

    func testVideoContextActionOpensAndClosesWindow() throws {
        try self.skipVideoWindowAssertionsOnMacOS15()
        launchWithMockPlayerWithVideo(isPlaying: true)
        navigateToHome()

        self.chooseVideoAction()
        XCTAssertTrue(waitForElement(self.videoWindow, timeout: 5))
        XCTAssertEqual(self.videoWindow.title, "Video")

        self.chooseVideoAction("Hide Video")
        XCTAssertTrue(self.videoWindow.waitForNonExistence(timeout: 5))
    }

    func testVideoWindowClosesOnRedButton() throws {
        try self.skipVideoWindowAssertionsOnMacOS15()
        launchWithMockPlayerWithVideo(isPlaying: true)
        navigateToHome()
        self.chooseVideoAction()
        XCTAssertTrue(waitForElement(self.videoWindow, timeout: 5))

        self.videoWindow.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(self.videoWindow.waitForNonExistence(timeout: 5))
        self.chooseVideoAction()
        XCTAssertTrue(waitForElement(self.videoWindow, timeout: 5))
    }

    func testUnifiedControlPersistsAcrossNavigation() {
        launchWithMockPlayerWithVideo(isPlaying: true)
        navigateToHome()
        XCTAssertTrue(waitForElement(self.floatingPlayerButton, timeout: 10))
        navigateToSearch()
        XCTAssertTrue(waitForElement(self.floatingPlayerButton))
        navigateToExplore()
        XCTAssertTrue(waitForElement(self.floatingPlayerButton))
    }
}
