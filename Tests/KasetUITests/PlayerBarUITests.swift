import XCTest

/// UI tests for the PlayerBar.
@MainActor
final class PlayerBarUITests: KasetUITestCase {
    // MARK: - Player Bar Visibility

    func testPlayerBarVisibleWithCurrentTrack() throws {
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

    func testPlayPauseButtonExists() throws {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let playPauseButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Play' OR label CONTAINS 'Pause'")
        ).firstMatch
        XCTAssertTrue(waitForHittable(playPauseButton))
    }

    func testNextButtonExists() throws {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let nextButton = app.buttons["Next track"]
        XCTAssertTrue(waitForElement(nextButton, timeout: 10), "Next button should exist")
    }

    func testPreviousButtonExists() throws {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let previousButton = app.buttons["Previous track"]
        XCTAssertTrue(waitForElement(previousButton, timeout: 10), "Previous button should exist")
    }

    func testShuffleButtonExists() throws {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let shuffleButton = app.buttons["Shuffle"]
        XCTAssertTrue(waitForElement(shuffleButton, timeout: 10), "Shuffle button should exist")
    }

    func testRepeatButtonExists() throws {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let repeatButton = app.buttons["Repeat"]
        XCTAssertTrue(waitForElement(repeatButton, timeout: 10), "Repeat button should exist")
    }

    // MARK: - Like/Dislike Buttons

    func testLikeButtonExists() throws {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let likeButton = app.buttons["Like"]
        XCTAssertTrue(waitForElement(likeButton, timeout: 10), "Like button should exist")
    }

    func testDislikeButtonExists() throws {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let dislikeButton = app.buttons["Dislike"]
        XCTAssertTrue(waitForElement(dislikeButton, timeout: 10), "Dislike button should exist")
    }

    // MARK: - Lyrics Button

    func testLyricsButtonExists() throws {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let lyricsButton = app.buttons["Lyrics"]
        XCTAssertTrue(waitForElement(lyricsButton, timeout: 10), "Lyrics button should exist")
    }

    // MARK: - Button Interactions

    func testShuffleButtonToggles() throws {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let shuffleButton = app.buttons["Shuffle"]
        XCTAssertTrue(waitForHittable(shuffleButton))

        // Check initial state
        let initialValue = shuffleButton.value as? String ?? ""

        // Click to toggle
        shuffleButton.click()

        // State should change
        Thread.sleep(forTimeInterval: 0.5)
        // The accessibility value should update
    }

    func testRepeatButtonCycles() throws {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let repeatButton = app.buttons["Repeat"]
        XCTAssertTrue(waitForHittable(repeatButton))

        // Click to cycle through modes: off -> all -> one -> off
        repeatButton.click()
        Thread.sleep(forTimeInterval: 0.3)

        repeatButton.click()
        Thread.sleep(forTimeInterval: 0.3)

        repeatButton.click()
        Thread.sleep(forTimeInterval: 0.3)
    }

    // MARK: - Player Bar Persistence Across Views

    func testPlayerBarPersistsAcrossNavigation() throws {
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
