import Foundation
import Testing
@testable import Kaset

/// Tests for Video Support functionality.
@Suite("Video Support", .serialized, .tags(.service))
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
