import XCTest

/// UI tests for the PlayerBar.
@MainActor
final class PlayerBarUITests: KasetUITestCase {
    // MARK: - Player Bar Visibility

    func testPlayerBarVisibleWithCurrentTrack() {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        // Player bar should be visible when there's a current track
        // Look for the play/pause button
        let playPauseButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Play' OR label CONTAINS 'Pause'")
        ).firstMatch
        XCTAssertTrue(waitForElement(playPauseButton, timeout: 10))
    }

    // MARK: - Playback Controls

    func testPlayPauseButtonExists() {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let playPauseButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Play' OR label CONTAINS 'Pause'")
        ).firstMatch
        XCTAssertTrue(waitForHittable(playPauseButton))
    }

    func testNextButtonExists() {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let nextButton = app.buttons["Next track"]
        XCTAssertTrue(waitForElement(nextButton, timeout: 10), "Next button should exist")
    }

    func testPreviousButtonExists() {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let previousButton = app.buttons["Previous track"]
        XCTAssertTrue(waitForElement(previousButton, timeout: 10), "Previous button should exist")
    }

    func testShuffleButtonExists() {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let shuffleButton = app.buttons["Shuffle"]
        XCTAssertTrue(waitForElement(shuffleButton, timeout: 10), "Shuffle button should exist")
    }

    func testRepeatButtonExists() {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let repeatButton = app.buttons["Repeat"]
        XCTAssertTrue(waitForElement(repeatButton, timeout: 10), "Repeat button should exist")
    }

    // MARK: - Like/Dislike Buttons

    func testLikeButtonExists() {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let likeButton = app.buttons["Like"]
        XCTAssertTrue(waitForElement(likeButton, timeout: 10), "Like button should exist")
    }

    func testDislikeButtonExists() {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let dislikeButton = app.buttons["Dislike"]
        XCTAssertTrue(waitForElement(dislikeButton, timeout: 10), "Dislike button should exist")
    }

    // MARK: - Lyrics Button

    func testLyricsButtonExists() {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let lyricsButton = app.buttons["Lyrics"]
        XCTAssertTrue(waitForElement(lyricsButton, timeout: 10), "Lyrics button should exist")
    }

    func testQueueButtonExists() {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let queueButton = app.buttons["Queue"]
        XCTAssertTrue(waitForElement(queueButton, timeout: 10), "Queue button should exist")
    }

    func testAirPlayButtonExists() {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let airPlayButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'AirPlay'")
        ).firstMatch
        XCTAssertTrue(waitForElement(airPlayButton, timeout: 10), "AirPlay button should exist")
    }

    func testVideoButtonExists() {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let videoButton = app.buttons[TestAccessibilityID.PlayerBar.videoButton]
        XCTAssertTrue(waitForElement(videoButton, timeout: 10), "Video button should exist")
    }

    func testMiniPlayerButtonExists() {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let miniPlayerButton = app.buttons[TestAccessibilityID.PlayerBar.miniPlayerButton]
        XCTAssertTrue(waitForElement(miniPlayerButton, timeout: 10), "Mini player button should exist")
    }

    // MARK: - Button Interactions

    func testLyricsButtonToggles() {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let lyricsButton = app.buttons["Lyrics"]
        XCTAssertTrue(waitForHittable(lyricsButton))

        lyricsButton.click()

        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(lyricsButton.value as? String, "Showing")
    }

    func testQueueButtonToggles() {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let queueButton = app.buttons["Queue"]
        XCTAssertTrue(waitForHittable(queueButton))

        queueButton.click()

        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(queueButton.value as? String, "Showing")
    }

    func testShuffleButtonToggles() {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let shuffleButton = app.buttons["Shuffle"]
        XCTAssertTrue(waitForHittable(shuffleButton))

        shuffleButton.click()

        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(shuffleButton.value as? String, "On")
    }

    func testRepeatButtonCycles() {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let repeatButton = app.buttons["Repeat"]
        XCTAssertTrue(waitForHittable(repeatButton))

        repeatButton.click()

        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertNotEqual(repeatButton.value as? String, "Off")
    }

    // MARK: - Player Bar Persistence Across Views

    func testPlayerBarPersistsAcrossNavigation() {
        launchWithMockPlayer(isPlaying: true)

        // Navigate to different views and verify player bar is present

        navigateToHome()
        var playPause = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Play' OR label CONTAINS 'Pause'")
        ).firstMatch
        XCTAssertTrue(waitForElement(playPause, timeout: 10))

        navigateToSearch()
        playPause = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Play' OR label CONTAINS 'Pause'")
        ).firstMatch
        XCTAssertTrue(waitForElement(playPause))

        navigateToExplore()
        playPause = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Play' OR label CONTAINS 'Pause'")
        ).firstMatch
        XCTAssertTrue(waitForElement(playPause))
    }
}
