import Foundation
import Testing
@testable import Kaset

@Suite(.serialized, .tags(.service))
@MainActor
struct VideoSupportTests {
    var playerService: PlayerService

    init() {
        UserDefaults.standard.removeObject(forKey: "playerVolume")
        UserDefaults.standard.removeObject(forKey: "playerVolumeBeforeMute")
        self.playerService = PlayerService()
    }

    @Test("currentTrackHasVideo initially false")
    func currentTrackHasVideoInitiallyFalse() {
        #expect(self.playerService.currentTrackHasVideo == false)
    }

    @Test("showVideo initially false")
    func showVideoInitiallyFalse() {
        #expect(self.playerService.showVideo == false)
    }

    @Test("updateVideoAvailability sets hasVideo correctly")
    func updateVideoAvailabilitySetsHasVideo() {
        #expect(self.playerService.currentTrackHasVideo == false)

        self.playerService.updateVideoAvailability(hasVideo: true)
        #expect(self.playerService.currentTrackHasVideo == true)

        self.playerService.updateVideoAvailability(hasVideo: false)
        #expect(self.playerService.currentTrackHasVideo == false)
    }

    @Test("showVideo stays open even when hasVideo becomes false")
    func showVideoStaysOpenWhenHasVideoChanges() {
        self.playerService.updateVideoAvailability(hasVideo: true)
        self.playerService.showVideo = true
        #expect(self.playerService.showVideo == true)

        self.playerService.updateVideoAvailability(hasVideo: false)
        #expect(self.playerService.showVideo == true, "Video window should NOT auto-close based on hasVideo")
    }

    @Test("showVideo can be enabled even when hasVideo is false")
    func showVideoCanBeEnabledWhenNoVideo() {
        #expect(self.playerService.currentTrackHasVideo == false)
        self.playerService.showVideo = true
        #expect(self.playerService.showVideo == true, "showVideo should be allowed even if hasVideo is false")
    }

    @Test("showVideo stays open when changing to another video track")
    func showVideoStaysOpenForVideoTrack() {
        self.playerService.updateVideoAvailability(hasVideo: true)
        self.playerService.showVideo = true
        #expect(self.playerService.showVideo == true)

        self.playerService.updateVideoAvailability(hasVideo: true)
        #expect(self.playerService.showVideo == true, "Video window should stay open")
    }

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

    @Test("SingletonPlayerWebView DisplayMode enum has all cases")
    func displayModeEnumHasAllCases() {
        let hidden = SingletonPlayerWebView.DisplayMode.hidden
        let miniPlayer = SingletonPlayerWebView.DisplayMode.miniPlayer
        let video = SingletonPlayerWebView.DisplayMode.video

        #expect(hidden == .hidden)
        #expect(miniPlayer == .miniPlayer)
        #expect(video == .video)
    }
}

@Suite(.tags(.service))
struct YouTubeVideoWindowFullscreenIntentStateTests {
    @Test("Failed fullscreen entry clears return-inline intent")
    func failureClearsReturnInlineIntent() {
        var state = YouTubeVideoWindowFullscreenIntentState()
        state.requestReturnInlineOnExit()

        state.cancelReturnInlineOnExit()

        let shouldReturn = state.consumeReturnInlineOnExit()
        #expect(!shouldReturn)
    }

    @Test("Return-inline intent is consumed once on fullscreen exit")
    func returnInlineIntentIsOneShot() {
        var state = YouTubeVideoWindowFullscreenIntentState()
        state.requestReturnInlineOnExit()

        let firstExit = state.consumeReturnInlineOnExit()
        let secondExit = state.consumeReturnInlineOnExit()
        #expect(firstExit)
        #expect(!secondExit)
    }
}

@Suite(.tags(.service))
struct YouTubeVideoWindowFrameAutosaveStateTests {
    private let autosaveName = "KasetYouTubeVideoWindow"

    @Test("Failed fullscreen entry restores frame autosaving")
    func failedEntryRestoresFrameAutosaving() {
        var state = YouTubeVideoWindowFrameAutosaveState(restorableName: self.autosaveName)

        state.handle(.willEnterFullScreen)
        #expect(state.currentName.isEmpty)

        state.handle(.didFailToEnterFullScreen)
        #expect(state.currentName == self.autosaveName)
    }

    @Test("Fullscreen exit restores frame autosaving")
    func exitRestoresFrameAutosaving() {
        var state = YouTubeVideoWindowFrameAutosaveState(restorableName: self.autosaveName)

        state.handle(.willEnterFullScreen)
        state.handle(.didExitFullScreen)

        #expect(state.currentName == self.autosaveName)
    }
}

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
        #expect(result == NSSize(width: 800, height: 450))
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
        let result = YouTubeVideoWindowResizeGuard.normalizedContentSize(
            for: NSSize(width: 800, height: 700),
            minContentSize: self.floor,
            current: NSSize(width: 800, height: 450)
        )
        #expect(result.height == 700)
        #expect(result.width == 1244)
    }

    @Test("Horizontal-edge drag still follows the proposed width")
    func widthDrivenWithCurrent() {
        let result = YouTubeVideoWindowResizeGuard.normalizedContentSize(
            for: NSSize(width: 1000, height: 450),
            minContentSize: self.floor,
            current: NSSize(width: 800, height: 450)
        )
        #expect(result.width == 1000)
        #expect(result.height == 563)
    }
}
