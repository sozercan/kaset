import XCTest

@MainActor
final class VideoUITests: KasetUITestCase {
    private var videoWindow: XCUIElement {
        app.windows.matching(NSPredicate(
            format: "identifier == %@ OR label == %@",
            TestAccessibilityID.VideoWindow.container,
            "Video"
        )).firstMatch
    }

    private func skipVideoWindowAssertionsOnMacOS15() throws {
        if #unavailable(macOS 26.0) {
            throw XCTSkip("Video window extraction is covered on macOS 26; macOS 15 CI only validates video control availability.")
        }
    }

    func testVideoButtonVisibleWhenNoVideo() {
        launchWithMockPlayer(isPlaying: true, hasVideo: false)

        navigateToHome()

        let videoButton = app.buttons[TestAccessibilityID.PlayerBar.videoButton]
        XCTAssertTrue(waitForElement(videoButton, timeout: 10), "Video button should stay visible when track has no video")
    }

    func testVideoButtonVisibleWhenTrackHasVideo() {
        launchWithMockPlayerWithVideo(isPlaying: true)

        navigateToHome()

        let videoButton = app.buttons[TestAccessibilityID.PlayerBar.videoButton]
        XCTAssertTrue(waitForElement(videoButton, timeout: 10), "Video button should exist when track has video")
    }

    func testVideoButtonAccessibilityLabel() {
        launchWithMockPlayerWithVideo(isPlaying: true)

        navigateToHome()

        let videoButton = app.buttons[TestAccessibilityID.PlayerBar.videoButton]
        XCTAssertTrue(waitForElement(videoButton, timeout: 10), "Video button should have 'Video' accessibility label")
    }

    func testVideoButtonIsClickable() {
        launchWithMockPlayerWithVideo(isPlaying: true)

        navigateToHome()

        let videoButton = app.buttons[TestAccessibilityID.PlayerBar.videoButton]
        XCTAssertTrue(waitForHittable(videoButton), "Video button should be clickable")
    }

    func testVideoButtonToggle() throws {
        try self.skipVideoWindowAssertionsOnMacOS15()

        launchWithMockPlayerWithVideo(isPlaying: true)

        navigateToHome()

        let videoButton = app.buttons[TestAccessibilityID.PlayerBar.videoButton]
        XCTAssertTrue(waitForHittable(videoButton))

        let initialValue = videoButton.value as? String ?? ""
        XCTAssertEqual(initialValue, "Off", "Video should initially be off")

        videoButton.click()
        Thread.sleep(forTimeInterval: 0.5)

        let afterClickValue = videoButton.value as? String ?? ""
        XCTAssertEqual(afterClickValue, "Playing", "Video should be playing after click")

        videoButton.click()
        Thread.sleep(forTimeInterval: 0.5)

        let afterSecondClickValue = videoButton.value as? String ?? ""
        XCTAssertEqual(afterSecondClickValue, "Off", "Video should be off after second click")
    }

    func testVideoWindowOpensOnButtonClick() throws {
        try self.skipVideoWindowAssertionsOnMacOS15()

        launchWithMockPlayerWithVideo(isPlaying: true)

        navigateToHome()

        let videoButton = app.buttons[TestAccessibilityID.PlayerBar.videoButton]
        XCTAssertTrue(waitForHittable(videoButton))

        videoButton.click()

        let videoWindow = self.videoWindow
        XCTAssertTrue(waitForElement(videoWindow, timeout: 5), "Video window should appear after clicking video button")
    }

    func testVideoWindowHasCorrectTitle() throws {
        try self.skipVideoWindowAssertionsOnMacOS15()

        launchWithMockPlayerWithVideo(isPlaying: true)

        navigateToHome()

        let videoButton = app.buttons[TestAccessibilityID.PlayerBar.videoButton]
        XCTAssertTrue(waitForHittable(videoButton))

        videoButton.click()

        let videoWindow = self.videoWindow
        XCTAssertTrue(waitForElement(videoWindow, timeout: 5))

        XCTAssertEqual(videoWindow.title, "Video", "Video window should have title 'Video'")
    }

    func testVideoWindowClosesOnRedButton() throws {
        try self.skipVideoWindowAssertionsOnMacOS15()

        launchWithMockPlayerWithVideo(isPlaying: true)

        navigateToHome()

        let videoButton = app.buttons[TestAccessibilityID.PlayerBar.videoButton]
        XCTAssertTrue(waitForHittable(videoButton))

        videoButton.click()

        let videoWindow = self.videoWindow
        XCTAssertTrue(waitForElement(videoWindow, timeout: 5))

        let closeButton = videoWindow.buttons[XCUIIdentifierCloseWindow]
        if closeButton.exists {
            closeButton.click()
            Thread.sleep(forTimeInterval: 0.5)

            XCTAssertFalse(videoWindow.exists, "Video window should close when close button clicked")

            let videoButtonValue = videoButton.value as? String ?? ""
            XCTAssertEqual(videoButtonValue, "Off", "Video button should show Off after window closed")
        }
    }

    func testVideoWindowClosesOnSecondButtonClick() throws {
        try self.skipVideoWindowAssertionsOnMacOS15()

        launchWithMockPlayerWithVideo(isPlaying: true)

        navigateToHome()

        let videoButton = app.buttons[TestAccessibilityID.PlayerBar.videoButton]
        XCTAssertTrue(waitForHittable(videoButton))

        videoButton.click()

        let videoWindow = self.videoWindow
        XCTAssertTrue(waitForElement(videoWindow, timeout: 5))

        videoButton.click()
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertFalse(videoWindow.exists, "Video window should close when video button clicked again")
    }

    func testVideoButtonPersistsAcrossNavigation() {
        launchWithMockPlayerWithVideo(isPlaying: true)

        navigateToHome()
        var videoButton = app.buttons[TestAccessibilityID.PlayerBar.videoButton]
        XCTAssertTrue(waitForElement(videoButton, timeout: 10), "Video button should be visible on Home")

        navigateToSearch()
        videoButton = app.buttons[TestAccessibilityID.PlayerBar.videoButton]
        XCTAssertTrue(waitForElement(videoButton), "Video button should be visible on Search")

        navigateToExplore()
        videoButton = app.buttons[TestAccessibilityID.PlayerBar.videoButton]
        XCTAssertTrue(waitForElement(videoButton), "Video button should be visible on Explore")
    }

    func testVideoPrimaryActionOpensWindow() throws {
        try self.skipVideoWindowAssertionsOnMacOS15()

        launchWithMockPlayerWithVideo(isPlaying: true)

        navigateToHome()

        let videoButton = app.buttons[TestAccessibilityID.PlayerBar.videoButton]
        XCTAssertTrue(waitForHittable(videoButton))

        let initialValue = videoButton.value as? String ?? ""
        XCTAssertEqual(initialValue, "Off")

        videoButton.click()

        let videoWindow = self.videoWindow
        XCTAssertTrue(waitForElement(videoWindow, timeout: 5), "Video window should open from the player control")

        let afterClickValue = videoButton.value as? String ?? ""
        XCTAssertEqual(afterClickValue, "Playing", "Video should be playing after clicking the player control")
    }

    func testVideoKeyboardShortcutTogglesWindow() throws {
        try self.skipVideoWindowAssertionsOnMacOS15()

        launchWithMockPlayerWithVideo(isPlaying: true)

        navigateToHome()

        let videoButton = app.buttons[TestAccessibilityID.PlayerBar.videoButton]
        XCTAssertTrue(waitForHittable(videoButton))
        XCTAssertEqual(videoButton.value as? String ?? "", "Off")

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(waitForElement(mainWindow, timeout: 5))
        mainWindow.click()
        app.typeKey("v", modifierFlags: [.command, .shift])

        let videoWindow = self.videoWindow
        XCTAssertTrue(
            waitForElement(videoWindow, timeout: 5),
            "Shift+Command+V should open the video window"
        )
        XCTAssertEqual(videoButton.value as? String ?? "", "Playing")

        app.typeKey("v", modifierFlags: [.command, .shift])
        XCTAssertTrue(
            waitForElementToDisappear(videoWindow, timeout: 5),
            "Shift+Command+V should close the video window"
        )
        XCTAssertEqual(videoButton.value as? String ?? "", "Off")
    }
}
