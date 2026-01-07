import XCTest

/// UI tests for Video functionality.
@MainActor
final class VideoUITests: KasetUITestCase {
    // MARK: - Video Button Visibility

    func testVideoButtonHiddenWhenNoVideo() throws {
        // Launch with player but no video support
        launchWithMockPlayer(isPlaying: true, hasVideo: false)

        navigateToHome()

        // Video button should NOT be visible when track has no video
        let videoButton = app.buttons[TestAccessibilityID.PlayerBar.videoButton]
        XCTAssertFalse(videoButton.exists, "Video button should be hidden when track has no video")
    }

    func testVideoButtonVisibleWhenTrackHasVideo() throws {
        // Launch with player that has video
        launchWithMockPlayerWithVideo(isPlaying: true)

        navigateToHome()

        // Video button should be visible when track has video
        let videoButton = app.buttons[TestAccessibilityID.PlayerBar.videoButton]
        XCTAssertTrue(waitForElement(videoButton, timeout: 10), "Video button should exist when track has video")
    }

    func testVideoButtonAccessibilityLabel() throws {
        launchWithMockPlayerWithVideo(isPlaying: true)

        navigateToHome()

        let videoButton = app.buttons["Video"]
        XCTAssertTrue(waitForElement(videoButton, timeout: 10), "Video button should have 'Video' accessibility label")
    }

    // MARK: - Video Button Interaction

    func testVideoButtonIsClickable() throws {
        launchWithMockPlayerWithVideo(isPlaying: true)

        navigateToHome()

        let videoButton = app.buttons[TestAccessibilityID.PlayerBar.videoButton]
        XCTAssertTrue(waitForHittable(videoButton), "Video button should be clickable")
    }

    func testVideoButtonToggle() throws {
        launchWithMockPlayerWithVideo(isPlaying: true)

        navigateToHome()

        let videoButton = app.buttons[TestAccessibilityID.PlayerBar.videoButton]
        XCTAssertTrue(waitForHittable(videoButton))

        // Check initial accessibility value
        let initialValue = videoButton.value as? String ?? ""
        XCTAssertEqual(initialValue, "Off", "Video should initially be off")

        // Click to open video
        videoButton.click()
        Thread.sleep(forTimeInterval: 0.5)

        // Value should change to "Playing"
        let afterClickValue = videoButton.value as? String ?? ""
        XCTAssertEqual(afterClickValue, "Playing", "Video should be playing after click")

        // Click again to close video
        videoButton.click()
        Thread.sleep(forTimeInterval: 0.5)

        // Value should change back to "Off"
        let afterSecondClickValue = videoButton.value as? String ?? ""
        XCTAssertEqual(afterSecondClickValue, "Off", "Video should be off after second click")
    }

    // MARK: - Video Window Tests

    func testVideoWindowOpensOnButtonClick() throws {
        launchWithMockPlayerWithVideo(isPlaying: true)

        navigateToHome()

        let videoButton = app.buttons[TestAccessibilityID.PlayerBar.videoButton]
        XCTAssertTrue(waitForHittable(videoButton))

        // Click video button
        videoButton.click()

        // Wait for video window to appear
        let videoWindow = app.windows[TestAccessibilityID.VideoWindow.container]
        XCTAssertTrue(waitForElement(videoWindow, timeout: 5), "Video window should appear after clicking video button")
    }

    func testVideoWindowHasCorrectTitle() throws {
        launchWithMockPlayerWithVideo(isPlaying: true)

        navigateToHome()

        let videoButton = app.buttons[TestAccessibilityID.PlayerBar.videoButton]
        XCTAssertTrue(waitForHittable(videoButton))

        videoButton.click()

        let videoWindow = app.windows[TestAccessibilityID.VideoWindow.container]
        XCTAssertTrue(waitForElement(videoWindow, timeout: 5))

        // Window title should be "Video"
        XCTAssertEqual(videoWindow.title, "Video", "Video window should have title 'Video'")
    }

    func testVideoWindowClosesOnRedButton() throws {
        launchWithMockPlayerWithVideo(isPlaying: true)

        navigateToHome()

        let videoButton = app.buttons[TestAccessibilityID.PlayerBar.videoButton]
        XCTAssertTrue(waitForHittable(videoButton))

        // Open video window
        videoButton.click()

        let videoWindow = app.windows[TestAccessibilityID.VideoWindow.container]
        XCTAssertTrue(waitForElement(videoWindow, timeout: 5))

        // Close button (red button)
        let closeButton = videoWindow.buttons[XCUIIdentifierCloseWindow]
        if closeButton.exists {
            closeButton.click()
            Thread.sleep(forTimeInterval: 0.5)

            // Video window should be gone
            XCTAssertFalse(videoWindow.exists, "Video window should close when close button clicked")

            // Video button state should be "Off"
            let videoButtonValue = videoButton.value as? String ?? ""
            XCTAssertEqual(videoButtonValue, "Off", "Video button should show Off after window closed")
        }
    }

    func testVideoWindowClosesOnSecondButtonClick() throws {
        launchWithMockPlayerWithVideo(isPlaying: true)

        navigateToHome()

        let videoButton = app.buttons[TestAccessibilityID.PlayerBar.videoButton]
        XCTAssertTrue(waitForHittable(videoButton))

        // Open video window
        videoButton.click()

        let videoWindow = app.windows[TestAccessibilityID.VideoWindow.container]
        XCTAssertTrue(waitForElement(videoWindow, timeout: 5))

        // Click video button again to close
        videoButton.click()
        Thread.sleep(forTimeInterval: 0.5)

        // Video window should be gone
        XCTAssertFalse(videoWindow.exists, "Video window should close when video button clicked again")
    }

    // MARK: - Video Button State Persistence

    func testVideoButtonPersistsAcrossNavigation() throws {
        launchWithMockPlayerWithVideo(isPlaying: true)

        // Navigate to different views and verify video button is present

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

    // MARK: - Keyboard Shortcut

    func testVideoKeyboardShortcut() throws {
        launchWithMockPlayerWithVideo(isPlaying: true)

        navigateToHome()

        let videoButton = app.buttons[TestAccessibilityID.PlayerBar.videoButton]
        XCTAssertTrue(waitForElement(videoButton, timeout: 10))

        // Initial state should be Off
        let initialValue = videoButton.value as? String ?? ""
        XCTAssertEqual(initialValue, "Off")

        // Use keyboard shortcut Cmd+Shift+V to open video
        app.typeKey("v", modifierFlags: [.command, .shift])

        // Wait for video window to appear as confirmation shortcut worked
        let videoWindow = app.windows[TestAccessibilityID.VideoWindow.container]
        XCTAssertTrue(waitForElement(videoWindow, timeout: 5), "Video window should open after keyboard shortcut")

        // Video button should now show Playing
        let afterShortcutValue = videoButton.value as? String ?? ""
        XCTAssertEqual(afterShortcutValue, "Playing", "Video should be playing after keyboard shortcut")
    }
}
