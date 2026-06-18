import Foundation
import Testing
@testable import Kaset

// MARK: - VideoSupportTests

/// Tests for Video Support functionality.
@Suite(.serialized, .tags(.service))
@MainActor
struct VideoSupportTests {
    var playerService: PlayerService

    init() {
        UserDefaults.standard.removeObject(forKey: "playerVolume")
        UserDefaults.standard.removeObject(forKey: "playerVolumeBeforeMute")
        self.playerService = PlayerService()
    }

    // MARK: - Initial State Tests

    @Test("currentTrackHasVideo initially false")
    func currentTrackHasVideoInitiallyFalse() {
        #expect(self.playerService.currentTrackHasVideo == false)
    }

    @Test("showVideo initially false")
    func showVideoInitiallyFalse() {
        #expect(self.playerService.showVideo == false)
    }

    // MARK: - Video Availability Tests

    @Test("updateVideoAvailability sets hasVideo correctly")
    func updateVideoAvailabilitySetsHasVideo() {
        #expect(self.playerService.currentTrackHasVideo == false)

        self.playerService.updateVideoAvailability(hasVideo: true)
        #expect(self.playerService.currentTrackHasVideo == true)

        self.playerService.updateVideoAvailability(hasVideo: false)
        #expect(self.playerService.currentTrackHasVideo == false)
    }

    // MARK: - Video Window Behavior Tests

    @Test("showVideo stays open even when hasVideo becomes false")
    func showVideoStaysOpenWhenHasVideoChanges() {
        // The video window should not auto-close based on hasVideo detection
        // because detection is unreliable when video mode CSS is active.
        // Only trackChanged should close the video window.
        self.playerService.updateVideoAvailability(hasVideo: true)
        self.playerService.showVideo = true
        #expect(self.playerService.showVideo == true)

        // hasVideo becomes false (unreliable detection during video mode)
        self.playerService.updateVideoAvailability(hasVideo: false)
        #expect(self.playerService.showVideo == true, "Video window should NOT auto-close based on hasVideo")
    }

    @Test("showVideo can be enabled even when hasVideo is false")
    func showVideoCanBeEnabledWhenNoVideo() {
        // We allow enabling showVideo even without hasVideo because:
        // 1. hasVideo detection might lag behind
        // 2. User explicitly requested video mode
        #expect(self.playerService.currentTrackHasVideo == false)
        self.playerService.showVideo = true
        #expect(self.playerService.showVideo == true, "showVideo should be allowed even if hasVideo is false")
    }

    @Test("showVideo stays open when changing to another video track")
    func showVideoStaysOpenForVideoTrack() {
        // Enable video with a video-capable track
        self.playerService.updateVideoAvailability(hasVideo: true)
        self.playerService.showVideo = true
        #expect(self.playerService.showVideo == true)

        // Track changes but still has video
        self.playerService.updateVideoAvailability(hasVideo: true)
        #expect(self.playerService.showVideo == true, "Video window should stay open")
    }

    // MARK: - Model Tests

    @Test("Song.hasVideo property exists and defaults to nil")
    func songHasVideoPropertyExists() {
        let song = Song(
            id: "test",
            title: "Test Song",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "test-video"
        )
        #expect(song.hasVideo == nil)
    }

    @Test("Song.hasVideo can be set explicitly")
    func songHasVideoCanBeSet() {
        let songWithVideo = Song(
            id: "test",
            title: "Test Song",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "test-video",
            hasVideo: true
        )
        #expect(songWithVideo.hasVideo == true)

        let songWithoutVideo = Song(
            id: "test2",
            title: "Test Song 2",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "test-video-2",
            hasVideo: false
        )
        #expect(songWithoutVideo.hasVideo == false)
    }

    // MARK: - Display Mode Tests

    @Test("SingletonPlayerWebView DisplayMode enum has all cases")
    func displayModeEnumHasAllCases() {
        let hidden = SingletonPlayerWebView.DisplayMode.hidden
        let miniPlayer = SingletonPlayerWebView.DisplayMode.miniPlayer
        let video = SingletonPlayerWebView.DisplayMode.video

        // Just verify the enum cases exist
        #expect(hidden == .hidden)
        #expect(miniPlayer == .miniPlayer)
        #expect(video == .video)
    }
}

// MARK: - YouTubeVideoWindowResizeGuardTests

@Suite(.tags(.service))
@MainActor
struct YouTubeVideoWindowResizeGuardTests {
    private let floor = NSSize(width: 512, height: 288)

    @Test("Width-driven resize snaps height to 16:9 (default)")
    func widthDrivenSnapsHeight() {
        let result = YouTubeVideoWindowResizeGuard.normalizedContentSize(
            for: NSSize(width: 800, height: 999),
            minContentSize: self.floor
        )
        #expect(result == NSSize(width: 800, height: 450)) // 800 * 9/16
    }

    @Test("Floor is enforced on both axes")
    func floorEnforced() {
        let result = YouTubeVideoWindowResizeGuard.normalizedContentSize(
            for: NSSize(width: 100, height: 100),
            minContentSize: self.floor
        )
        #expect(result == self.floor)
    }

    @Test("Vertical-edge drag follows the proposed height")
    func heightDrivenFollowsHeight() {
        // Current 800x450; user drags the bottom edge to make it taller. Width is
        // unchanged, height grew — the clamp must follow the height, not snap it
        // back to the old width-derived value. width = round(700 * 16/9) = 1244.
        let result = YouTubeVideoWindowResizeGuard.normalizedContentSize(
            for: NSSize(width: 800, height: 700),
            minContentSize: self.floor,
            current: NSSize(width: 800, height: 450)
        )
        #expect(result.height == 700)
        #expect(result.width == 1244) // followed the height, not snapped to 800
    }

    @Test("Horizontal-edge drag still follows the proposed width")
    func widthDrivenWithCurrent() {
        // width unchanged-axis is the bigger delta, so drive off width:
        // height = round(1000 * 9/16) = round(562.5) = 563.
        let result = YouTubeVideoWindowResizeGuard.normalizedContentSize(
            for: NSSize(width: 1000, height: 450),
            minContentSize: self.floor,
            current: NSSize(width: 800, height: 450)
        )
        #expect(result.width == 1000)
        #expect(result.height == 563)
    }
}
