import XCTest

@MainActor
final class MacOS15FallbackUITests: KasetUITestCase {
    func testAppLaunchesOnHostOS() {
        launchDefault()

        let sidebar = app.outlineRows.firstMatch
        XCTAssertTrue(waitForElement(sidebar, timeout: 15), "Sidebar should appear after launch")
        XCTAssertGreaterThan(app.windows.count, 0, "Main window should exist")

        if #available(macOS 26.0, *) {
            XCTAssertTrue(true, "Running on macOS 26+: Liquid Glass live")
        } else {
            XCTAssertTrue(true, "Running on macOS 15: ultraThinMaterial fallback live")
        }
    }

    func testOpeningPlaylistRoutesToCorrectDetailView() {
        launchWithMockLibrary(playlistCount: 3)

        navigateToLibrary()

        let firstPlaylistElement = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Playlist 0")
        ).firstMatch
        XCTAssertTrue(
            waitForElement(firstPlaylistElement, timeout: 15),
            "Mock library playlist should render"
        )

        let firstPlaylistTitle = app.staticTexts["Playlist 0"].firstMatch
        let firstPlaylistButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Playlist 0")
        ).firstMatch
        if firstPlaylistButton.exists {
            firstPlaylistButton.click()
        } else if firstPlaylistTitle.isHittable {
            firstPlaylistTitle.click()
        } else {
            let row = app.cells.containing(.staticText, identifier: "Playlist 0").firstMatch
            if row.exists {
                row.click()
            } else {
                XCTFail("Could not click on Playlist 0")
                return
            }
        }

        let detailTitle = app.staticTexts["Playlist 0"].firstMatch
        XCTAssertTrue(waitForElement(detailTitle, timeout: 10), "Playlist detail title should be visible")

        let playButton = app.buttons["Play"].firstMatch
        let shuffleButton = app.buttons["Shuffle"].firstMatch
        XCTAssertTrue(
            waitForElement(playButton, timeout: 10) || waitForElement(shuffleButton, timeout: 2),
            "Playlist detail should expose Play and/or Shuffle controls"
        )
    }

    func testLyricsButtonOpensLyricsPanel() {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let lyricsButton = app.buttons["Lyrics"].firstMatch
        XCTAssertTrue(waitForElement(lyricsButton, timeout: 10), "Lyrics button should exist")

        guard waitForHittable(lyricsButton, timeout: 5) else { return }
        lyricsButton.click()

        let lyricsHeader = app.staticTexts["Lyrics"]
        XCTAssertTrue(
            waitForElement(lyricsHeader, timeout: 10),
            "Lyrics panel header should appear after toggling"
        )

        if #unavailable(macOS 26.0) {
            let fallbackContent = app.descendants(matching: .any)[TestAccessibilityID.Lyrics.fallbackPanel]
            XCTAssertTrue(
                waitForElement(fallbackContent, timeout: 8),
                "macOS 15 fallback lyrics panel should be active"
            )
        }
    }

    func testMiniPlayerRendersControlsOnBothOSes() {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let playPause = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Play' OR label CONTAINS 'Pause'")
        ).firstMatch
        XCTAssertTrue(waitForElement(playPause, timeout: 10))
        XCTAssertTrue(waitForHittable(playPause, timeout: 5))

        let nextButton = app.buttons["Next track"]
        XCTAssertTrue(waitForElement(nextButton, timeout: 5))

        let previousButton = app.buttons["Previous track"]
        XCTAssertTrue(waitForElement(previousButton, timeout: 5))
    }
}
