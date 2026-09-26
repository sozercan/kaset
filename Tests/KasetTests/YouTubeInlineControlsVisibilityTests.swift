import Foundation
import Testing
@testable import Kaset

@Suite("YouTube inline controls visibility", .tags(.model))
struct YouTubeInlineControlsVisibilityTests {
    @Test("Controls hide during idle playback")
    func hideDuringIdlePlayback() {
        #expect(!Self.shouldShow())
    }

    @Test("Controls stay visible while paused")
    func visibleWhilePaused() {
        #expect(Self.shouldShow(isPlaying: false))
    }

    @Test("Each interaction keeps the controls visible during playback")
    func interactionsKeepControlsVisible() {
        #expect(Self.shouldShow(isRecentlyActive: true))
        #expect(Self.shouldShow(isPointerOverControls: true))
        #expect(Self.shouldShow(isControlPopupOpen: true))
    }

    @Test("VoiceOver or Tabbing with Keyboard Navigation keeps the controls reachable during playback")
    func assistiveNavigationKeepsControlsVisible() {
        #expect(Self.shouldShow(isAssistiveNavigationActive: true))
    }

    @Test("Controls region counts as visible only when its whole strip is in the scroll view")
    func controlsRegionVisibility() {
        let video = CGSize(width: 1600, height: 900)
        // Top of the page, viewport taller than the video.
        #expect(YouTubeInlineControlsVisibility.isControlsRegionVisible(
            videoSize: video,
            visibleBounds: CGRect(x: 0, y: -20, width: 1600, height: 1000)
        ))
        // Tall video in a short window: most of it shows, but its bottom
        // strip is below the fold.
        #expect(!YouTubeInlineControlsVisibility.isControlsRegionVisible(
            videoSize: video,
            visibleBounds: CGRect(x: 0, y: -20, width: 1600, height: 700)
        ))
        // Scrolled down until the strip passes under the top edge.
        #expect(!YouTubeInlineControlsVisibility.isControlsRegionVisible(
            videoSize: video,
            visibleBounds: CGRect(x: 0, y: 870, width: 1600, height: 700)
        ))
        // Scrolled so the strip sits just inside the top edge.
        #expect(YouTubeInlineControlsVisibility.isControlsRegionVisible(
            videoSize: video,
            visibleBounds: CGRect(x: 0, y: 840, width: 1600, height: 700)
        ))
        // Outside a scroll view there is nothing to scroll away from.
        #expect(YouTubeInlineControlsVisibility.isControlsRegionVisible(
            videoSize: video,
            visibleBounds: nil
        ))
    }

    private static func shouldShow(
        isPlaying: Bool = true,
        isRecentlyActive: Bool = false,
        isPointerOverControls: Bool = false,
        isControlPopupOpen: Bool = false,
        isAssistiveNavigationActive: Bool = false
    ) -> Bool {
        YouTubeInlineControlsVisibility.shouldShow(
            isPlaying: isPlaying,
            isRecentlyActive: isRecentlyActive,
            isPointerOverControls: isPointerOverControls,
            isControlPopupOpen: isControlPopupOpen,
            isAssistiveNavigationActive: isAssistiveNavigationActive
        )
    }
}
