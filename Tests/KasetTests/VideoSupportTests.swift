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
        // Keep the quality-discovery retry path from blocking on real time.
        PlayerService.videoQualityRetryDelay = .zero
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

    // MARK: - Video Quality Tests

    @Test("Video quality state starts empty")
    func videoQualityStartsEmpty() {
        #expect(self.playerService.videoQualityLevels.isEmpty)
        #expect(self.playerService.currentVideoQuality == nil)
    }

    @Test("selectVideoQuality optimistically records the chosen level")
    func selectVideoQualityRecordsLevel() {
        // No WebView in unit tests, so the underlying JS call is a no-op; the
        // service still updates its observable state for the menu checkmark.
        self.playerService.selectVideoQuality("hd720")
        #expect(self.playerService.currentVideoQuality == "hd720")

        self.playerService.selectVideoQuality("large")
        #expect(self.playerService.currentVideoQuality == "large")
    }

    @Test("resetVideoQualityOptions clears levels, current, and the fetch guard")
    func resetVideoQualityOptionsClearsState() {
        self.playerService.videoQualityLevels = ["hd720", "large", "auto"]
        self.playerService.currentVideoQuality = "hd720"
        self.playerService.videoQualityOptionsVideoId = "abc"

        self.playerService.resetVideoQualityOptions()

        #expect(self.playerService.videoQualityLevels.isEmpty)
        #expect(self.playerService.currentVideoQuality == nil)
        #expect(self.playerService.videoQualityOptionsVideoId == nil)
    }

    @Test("resetTrackStatus leaves video quality untouched (videoId-keyed instead)")
    func resetTrackStatusKeepsVideoQuality() {
        self.playerService.videoQualityLevels = ["hd1080", "hd720"]
        self.playerService.currentVideoQuality = "hd1080"

        // Quality clearing is intentionally decoupled from resetTrackStatus so a
        // same-videoId metadata refresh doesn't blank the picker.
        self.playerService.resetTrackStatus()

        #expect(self.playerService.videoQualityLevels == ["hd1080", "hd720"])
        #expect(self.playerService.currentVideoQuality == "hd1080")
    }

    @Test("YouTubeQuality.displayName maps the levels the music player reports")
    func qualityDisplayNamesMapMusicLevels() {
        // The runtime probe confirmed music's #movie_player reports exactly
        // these identifiers; the display helper is shared with the YouTube side.
        #expect(YouTubeQuality.displayName(for: "hd720") == "720p")
        #expect(YouTubeQuality.displayName(for: "large") == "480p")
        #expect(YouTubeQuality.displayName(for: "medium") == "360p")
        #expect(YouTubeQuality.displayName(for: "small") == "240p")
        #expect(YouTubeQuality.displayName(for: "tiny") == "144p")
        #expect(YouTubeQuality.displayName(for: "auto") == String(localized: "Auto"))
    }

    // MARK: - Video Quality Discovery Tests

    private func makeVideoSong(_ videoId: String) -> Song {
        Song(
            id: videoId,
            title: "Song \(videoId)",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: videoId,
            hasVideo: true
        )
    }

    @Test("Discovery fetches the current video's levels once, latching on success")
    func discoveryFetchesAndLatches() async {
        let source = MockMusicVideoQualitySource()
        source.levels = ["hd1080", "hd720", "auto"]
        source.current = "hd720"
        source.loadedId = "abc"
        self.playerService.videoQualitySource = source
        self.playerService.currentTrack = self.makeVideoSong("abc")
        self.playerService.showVideo = true

        await self.playerService.refreshVideoQualityOptionsIfNeeded()
        #expect(self.playerService.videoQualityLevels == ["hd1080", "hd720", "auto"])
        #expect(self.playerService.currentVideoQuality == "hd720")
        #expect(self.playerService.videoQualityOptionsVideoId == "abc")

        // Idempotent: a second call for the same video does not re-fetch.
        await self.playerService.refreshVideoQualityOptionsIfNeeded()
        #expect(source.availableCallCount == 1)
    }

    @Test("Track change while video mode stays open re-discovers levels")
    func discoveryFollowsTrackChange() async {
        let source = MockMusicVideoQualitySource()
        source.levels = ["hd720", "auto"]
        source.loadedId = "first"
        self.playerService.videoQualitySource = source
        self.playerService.showVideo = true
        self.playerService.currentTrack = self.makeVideoSong("first")

        await self.playerService.refreshVideoQualityOptionsIfNeeded()
        #expect(self.playerService.videoQualityOptionsVideoId == "first")
        #expect(self.playerService.videoQualityLevels == ["hd720", "auto"])

        // Simulate the next song: the track changes and the player navigates to
        // the new video. Discovery itself clears the previous levels before
        // fetching the new ones (resetTrackStatus no longer touches quality).
        source.levels = ["hd1080", "hd720", "auto"]
        source.loadedId = "second"
        self.playerService.currentTrack = self.makeVideoSong("second")

        await self.playerService.refreshVideoQualityOptionsIfNeeded()
        #expect(self.playerService.videoQualityLevels == ["hd1080", "hd720", "auto"])
        #expect(self.playerService.videoQualityOptionsVideoId == "second")
        #expect(source.availableCallCount == 2)
    }

    @Test("A single discovery call retries internally until the player is ready")
    func discoveryRetriesInternallyUntilReady() async {
        let source = MockMusicVideoQualitySource()
        source.levels = ["hd720", "auto"]
        source.loadedId = "abc"
        source.emptyUntilCall = 2 // empty on attempt 1, ready on attempt 2
        self.playerService.videoQualitySource = source
        self.playerService.showVideo = true
        self.playerService.currentTrack = self.makeVideoSong("abc")

        // One call self-heals: it retries internally rather than relying on a
        // future onChange event for the same video.
        await self.playerService.refreshVideoQualityOptionsIfNeeded()

        #expect(self.playerService.videoQualityLevels == ["hd720", "auto"])
        #expect(self.playerService.videoQualityOptionsVideoId == "abc")
        #expect(source.availableCallCount == 2)
    }

    @Test("Discovery does not latch when the player never becomes ready")
    func discoveryDoesNotLatchWhenNeverReady() async {
        let source = MockMusicVideoQualitySource()
        source.levels = [] // player never reports levels
        source.loadedId = "abc"
        self.playerService.videoQualitySource = source
        self.playerService.showVideo = true
        self.playerService.currentTrack = self.makeVideoSong("abc")

        await self.playerService.refreshVideoQualityOptionsIfNeeded()

        #expect(self.playerService.videoQualityLevels.isEmpty)
        // Guard NOT latched, so a later event can retry the same video.
        #expect(self.playerService.videoQualityOptionsVideoId == nil)
        #expect(source.availableCallCount == 3) // exhausted the retry budget
    }

    @Test("Discovery does not latch the previous page's levels after a skip")
    func discoveryWaitsForLoadedVideo() async {
        // The player still has the previous video loaded (loadedId != requested),
        // but reports non-empty levels for it. Discovery must NOT store those
        // under the new videoId.
        let source = MockMusicVideoQualitySource()
        source.levels = ["hd1080", "hd720", "auto"] // previous page's levels
        source.loadedId = "previous" // page hasn't navigated to "new" yet
        self.playerService.videoQualitySource = source
        self.playerService.showVideo = true
        self.playerService.currentTrack = self.makeVideoSong("new")

        await self.playerService.refreshVideoQualityOptionsIfNeeded()

        // Loaded id never matched the requested video, so nothing latched and
        // the stale levels were never read.
        #expect(self.playerService.videoQualityLevels.isEmpty)
        #expect(self.playerService.videoQualityOptionsVideoId == nil)
        #expect(source.availableCallCount == 0)
    }

    @Test("Discovery latches once the loaded video catches up to the request")
    func discoveryLatchesWhenLoadedCatchesUp() async {
        let source = MockMusicVideoQualitySource()
        source.levels = ["hd720", "auto"]
        source.loadedId = "stale" // first probe: page still on the old video
        source.loadedIdAfterCall = (call: 2, id: "target") // ready on 2nd probe
        self.playerService.videoQualitySource = source
        self.playerService.showVideo = true
        self.playerService.currentTrack = self.makeVideoSong("target")

        await self.playerService.refreshVideoQualityOptionsIfNeeded()

        #expect(self.playerService.videoQualityLevels == ["hd720", "auto"])
        #expect(self.playerService.videoQualityOptionsVideoId == "target")
    }

    @Test("Discovery is a no-op when video mode is closed")
    func discoverySkippedWhenVideoClosed() async {
        let source = MockMusicVideoQualitySource()
        source.levels = ["hd720"]
        source.loadedId = "abc"
        self.playerService.videoQualitySource = source
        self.playerService.currentTrack = self.makeVideoSong("abc")
        self.playerService.showVideo = false

        await self.playerService.refreshVideoQualityOptionsIfNeeded()
        #expect(self.playerService.videoQualityLevels.isEmpty)
        #expect(source.availableCallCount == 0)
    }

    @Test("Skipping clears the previous video's displayed levels immediately")
    func skipClearsStaleDisplayedLevels() async {
        // First video populated.
        let source = MockMusicVideoQualitySource()
        source.levels = ["hd1080", "hd720", "auto"]
        source.loadedId = "first"
        self.playerService.videoQualitySource = source
        self.playerService.showVideo = true
        self.playerService.currentTrack = self.makeVideoSong("first")
        await self.playerService.refreshVideoQualityOptionsIfNeeded()
        #expect(!self.playerService.videoQualityLevels.isEmpty)

        // Skip: new track, but the page is still on the old video and not ready.
        source.loadedId = "second" // pretend page navigated but reports no levels yet
        source.levels = []
        self.playerService.currentTrack = self.makeVideoSong("second")

        await self.playerService.refreshVideoQualityOptionsIfNeeded()

        // The old video's resolutions must not linger on screen while the new
        // page loads — the menu should be empty, not showing stale options.
        #expect(self.playerService.videoQualityLevels.isEmpty)
        #expect(self.playerService.currentVideoQuality == nil)
    }

    @Test("Same-video resetTrackStatus does not clear quality levels")
    func sameVideoResetKeepsQuality() async {
        let source = MockMusicVideoQualitySource()
        source.levels = ["hd720", "auto"]
        source.loadedId = "abc"
        self.playerService.videoQualitySource = source
        self.playerService.showVideo = true
        self.playerService.currentTrack = self.makeVideoSong("abc")
        await self.playerService.refreshVideoQualityOptionsIfNeeded()
        #expect(!self.playerService.videoQualityLevels.isEmpty)

        // A same-video metadata refresh (title/artist glitch) calls
        // resetTrackStatus; it must NOT blank the quality picker, since nothing
        // would re-trigger discovery for the unchanged videoId.
        self.playerService.resetTrackStatus()

        #expect(self.playerService.videoQualityLevels == ["hd720", "auto"])
        #expect(self.playerService.videoQualityOptionsVideoId == "abc")
    }

    @Test("Returning to a previously-fetched video re-discovers after a failed skip")
    func returnToVideoAfterFailedSkipRediscovers() async {
        let source = MockMusicVideoQualitySource()
        source.levels = ["hd1080", "hd720", "auto"]
        source.loadedId = "A"
        self.playerService.videoQualitySource = source
        self.playerService.showVideo = true

        // Video A latches its options.
        self.playerService.currentTrack = self.makeVideoSong("A")
        await self.playerService.refreshVideoQualityOptionsIfNeeded()
        #expect(self.playerService.videoQualityOptionsVideoId == "A")

        // Skip to B, which never becomes ready (page stays on A / reports empty).
        source.loadedId = "A" // page hasn't navigated to B
        source.levels = []
        self.playerService.currentTrack = self.makeVideoSong("B")
        await self.playerService.refreshVideoQualityOptionsIfNeeded()
        #expect(self.playerService.videoQualityLevels.isEmpty)
        // Guard was reset when probing B, so it is NOT stuck on "A".
        #expect(self.playerService.videoQualityOptionsVideoId == nil)

        // Return to A while video mode is still open — it must re-discover.
        source.loadedId = "A"
        source.levels = ["hd1080", "hd720", "auto"]
        self.playerService.currentTrack = self.makeVideoSong("A")
        await self.playerService.refreshVideoQualityOptionsIfNeeded()
        #expect(self.playerService.videoQualityLevels == ["hd1080", "hd720", "auto"])
        #expect(self.playerService.videoQualityOptionsVideoId == "A")
    }

    @Test("Quality state resets when the track goes nil via resetVideoQualityOptions")
    func nilTrackClearsQuality() async {
        let source = MockMusicVideoQualitySource()
        source.levels = ["hd720", "auto"]
        source.loadedId = "abc"
        self.playerService.videoQualitySource = source
        self.playerService.showVideo = true
        self.playerService.currentTrack = self.makeVideoSong("abc")
        await self.playerService.refreshVideoQualityOptionsIfNeeded()
        #expect(!self.playerService.videoQualityLevels.isEmpty)

        // stop() nils currentTrack while video mode stays open; MainWindow's
        // nil-videoId branch calls resetVideoQualityOptions (exercised directly
        // here) so the stale picker doesn't linger with no active track.
        self.playerService.resetVideoQualityOptions()

        #expect(self.playerService.videoQualityLevels.isEmpty)
        #expect(self.playerService.currentVideoQuality == nil)
        #expect(self.playerService.videoQualityOptionsVideoId == nil)
    }
}

// MARK: - MockMusicVideoQualitySource

/// Records quality-source calls so discovery logic can be tested headlessly.
@MainActor
private final class MockMusicVideoQualitySource: MusicVideoQualitySource {
    var levels: [String] = []
    var current: String?
    private(set) var availableCallCount = 0
    private(set) var loadedCallCount = 0
    private(set) var setLevels: [String] = []

    /// The videoId the "player" currently reports as loaded. Defaults to nil
    /// (no video loaded); tests set it to the requested id to simulate a ready
    /// page, or to a different id to simulate the page lagging behind a skip.
    var loadedId: String?

    /// When set, `loadedVideoId()` switches to `id` once it has been called at
    /// least `call` times — simulating the page finishing navigation mid-retry.
    var loadedIdAfterCall: (call: Int, id: String)?

    /// When set, `availableQualityLevels()` returns `[]` until this many calls
    /// have been made, then returns `levels` — simulating a player that becomes
    /// ready after a couple of probes.
    var emptyUntilCall = 0

    func loadedVideoId() async -> String? {
        self.loadedCallCount += 1
        if let ready = self.loadedIdAfterCall, self.loadedCallCount >= ready.call {
            return ready.id
        }
        return self.loadedId
    }

    func availableQualityLevels() async -> [String] {
        self.availableCallCount += 1
        if self.availableCallCount < self.emptyUntilCall {
            return []
        }
        return self.levels
    }

    func currentQualityLevel() async -> String? {
        self.current
    }

    func setQualityLevel(_ level: String) {
        self.setLevels.append(level)
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
