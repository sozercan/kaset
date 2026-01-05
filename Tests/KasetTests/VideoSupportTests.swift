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

    // MARK: - Auto-Close Tests

    @Test("showVideo auto-closes when track has no video")
    func showVideoAutoClosesWhenNoVideo() {
        // First, enable video with a video-capable track
        self.playerService.updateVideoAvailability(hasVideo: true)
        self.playerService.showVideo = true
        #expect(self.playerService.showVideo == true)

        // Then track changes to one without video
        self.playerService.updateVideoAvailability(hasVideo: false)
        #expect(self.playerService.showVideo == false, "Video window should auto-close")
    }

    @Test("showVideo cannot be enabled when no video available")
    func showVideoCannotBeEnabledWhenNoVideo() {
        #expect(self.playerService.currentTrackHasVideo == false)
        self.playerService.showVideo = true
        #expect(self.playerService.showVideo == false, "showVideo should stay false when no video available")
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
