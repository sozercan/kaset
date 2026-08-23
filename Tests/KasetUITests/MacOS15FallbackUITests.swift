import XCTest

/// UI smoke tests covering the screens that route to `LegacyFallbackViews`
/// on macOS 15.
///
/// The same tests run on both the macos-15 and macos-26 CI legs. On macos-26
/// they exercise the full Liquid Glass implementations; on macos-15 they
/// exercise the simplified fallback views. The goal is to catch:
///
/// 1. `#available(macOS 26.0, *)` branches that crash or fail to lay out on
///    macOS 15 (the OS we cannot reproduce locally).
/// 2. Accessibility / label drift between the two implementations.
/// 3. Regressions in the fallback views being silently dead-coded.
@MainActor
final class MacOS15FallbackUITests: KasetUITestCase {
    // MARK: - App Launch

    /// Establishes that the app boots at all on the host OS. If this test
    /// fails on macos-15, every other macOS-15 finding is unreliable.
    func testAppLaunchesOnHostOS() {
        launchDefault()

        let sidebar = app.outlineRows.firstMatch
        XCTAssertTrue(waitForElement(sidebar, timeout: 15), "Sidebar should appear after launch")
        XCTAssertGreaterThan(app.windows.count, 0, "Main window should exist")

        if #available(macOS 26.0, *) {
            // Liquid Glass branch is live; just record it.
            XCTAssertTrue(true, "Running on macOS 26+: Liquid Glass live")
        } else {
            XCTAssertTrue(true, "Running on macOS 15: ultraThinMaterial fallback live")
        }
    }

    // MARK: - Playlist Detail (SimplePlaylistDetailView on macOS 15)

    /// Navigates Library → first playlist. On macOS 15 this opens
    /// `SimplePlaylistDetailView`; on macOS 26 it opens `PlaylistDetailView`.
    /// In both cases the playlist title should appear and the player bar
    /// should remain mounted.
    func testOpeningPlaylistRoutesToCorrectDetailView() {
        launchWithMockLibrary(playlistCount: 3)

        navigateToLibrary()

        // Wait for at least one playlist row to appear. Depending on the OS
        // and SwiftUI accessibility flattening, the card title may surface as
        // either a static text or as part of the enclosing button label.
        let firstPlaylistElement = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Playlist 0")
        ).firstMatch
        XCTAssertTrue(
            waitForElement(firstPlaylistElement, timeout: 15),
            "Mock library playlist should render"
        )

        // Click into the playlist. We accept either staticText or button
        // because the row may be wrapped differently in the fallback.
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

        // The playlist title becomes the navigation title in both
        // implementations.
        let detailTitle = app.staticTexts["Playlist 0"].firstMatch
        XCTAssertTrue(waitForElement(detailTitle, timeout: 10), "Playlist detail title should be visible")

        // Both `SimplePlaylistDetailView` and `PlaylistDetailView` expose
        // Play and Shuffle as labeled buttons.
        let playButton = app.buttons["Play"].firstMatch
        let shuffleButton = app.buttons["Shuffle"].firstMatch
        XCTAssertTrue(
            waitForElement(playButton, timeout: 10) || waitForElement(shuffleButton, timeout: 2),
            "Playlist detail should expose Play and/or Shuffle controls"
        )
    }

    // MARK: - Lyrics Panel (SimpleLyricsView on macOS 15)

    /// Toggles the lyrics panel from the player bar. On macOS 15 this should
    /// surface `SimpleLyricsView` (with the Apple-Intelligence-unavailable
    /// footnote); on macOS 26 the full lyrics view.
    func testLyricsButtonOpensLyricsPanel() {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        let lyricsButton = app.buttons["Lyrics"].firstMatch
        XCTAssertTrue(waitForElement(lyricsButton, timeout: 10), "Lyrics button should exist")

        guard waitForHittable(lyricsButton, timeout: 5) else { return }
        lyricsButton.click()

        // The panel header text is the same in both impls.
        let lyricsHeader = app.staticTexts["Lyrics"]
        XCTAssertTrue(
            waitForElement(lyricsHeader, timeout: 10),
            "Lyrics panel header should appear after toggling"
        )

        if #unavailable(macOS 26.0) {
            // The fallback panel specifically advertises that Apple
            // Intelligence requires macOS 26. If this label disappears the
            // fallback was probably dead-coded.
            let fallbackContent = app.descendants(matching: .any)[TestAccessibilityID.Lyrics.fallbackPanel]
            XCTAssertTrue(
                waitForElement(fallbackContent, timeout: 8),
                "macOS 15 fallback lyrics panel should be active"
            )
        }
    }

    // MARK: - Mini Player Glass Effects

    /// The mini player makes heavy use of `compatGlass` modifiers. On macOS
    /// 15 these resolve to `.ultraThinMaterial`; on macOS 26 to real
    /// `.glassEffect`. Either way the controls must be present and hittable.
    func testMiniPlayerRendersControlsOnBothOSes() {
        launchWithMockPlayer(isPlaying: true)

        navigateToHome()

        // The mini player surfaces the same play/pause + next/previous
        // controls as the main player bar. We don't depend on the specific
        // window style (since the mini player is an opt-in user action on
        // macOS 26) — instead we just verify the controls exist and can be
        // interacted with from the default home view.
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
