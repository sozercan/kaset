// swiftlint:disable file_length
import Foundation
import Testing
@testable import Kaset

// MARK: - MockYouTubeWatchPlaybackController

/// Records playback commands without touching a real WebView.
@MainActor
final class MockYouTubeWatchPlaybackController: YouTubeWatchPlaybackControlling {
    private(set) var loadedVideoIds: [String] = []
    private(set) var reloadedVideoIds: [String] = []
    private(set) var reloadResumeSeconds: [Double?] = []
    private(set) var playPauseCount = 0
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var seeks: [Double] = []
    private(set) var pendingRecoverySeeks: [Double] = []
    private(set) var cancelPendingRecoverySeekCount = 0
    private(set) var markCurrentPlaybackOccurrenceEndedCount = 0
    private(set) var commandLog: [String] = []
    private(set) var volumes: [Double] = []
    private(set) var tearDownCount = 0
    private(set) var prepareCount = 0
    private(set) var cancelPendingLoadCount = 0
    var cancelPendingLoadResult = false
    var onLoadVideo: ((String) -> Void)?
    var onSeek: ((Double) -> Void)?

    func prepare(webKitManager _: WebKitManager, playerService _: YouTubePlayerService, usesCookieFreeDataStore _: Bool) {
        self.prepareCount += 1
    }

    func loadVideo(videoId: String) {
        self.loadedVideoIds.append(videoId)
        self.onLoadVideo?(videoId)
    }

    func reloadVideo(videoId: String, resumeAt seconds: Double?) {
        self.reloadedVideoIds.append(videoId)
        self.reloadResumeSeconds.append(seconds)
    }

    func cancelPendingLoad() -> Bool {
        self.cancelPendingLoadCount += 1
        return self.cancelPendingLoadResult
    }

    func playPause() {
        self.playPauseCount += 1
    }

    func play() {
        self.commandLog.append("play")
        self.playCount += 1
    }

    func pause() {
        self.commandLog.append("pause")
        self.pauseCount += 1
    }

    func seek(to time: Double) {
        self.commandLog.append("seek")
        self.seeks.append(time)
        self.onSeek?(time)
    }

    func replacePendingRecoverySeek(with seconds: Double) {
        self.commandLog.append("replacePendingRecoverySeek")
        self.pendingRecoverySeeks.append(seconds)
    }

    func seekWithRecovery(to seconds: Double) {
        self.replacePendingRecoverySeek(with: seconds)
        self.seek(to: seconds)
    }

    func cancelPendingRecoverySeek() {
        self.commandLog.append("cancelPendingRecoverySeek")
        self.cancelPendingRecoverySeekCount += 1
    }

    func markCurrentPlaybackOccurrenceEnded() {
        self.commandLog.append("markCurrentPlaybackOccurrenceEnded")
        self.markCurrentPlaybackOccurrenceEndedCount += 1
    }

    func resetCommandLog() {
        self.commandLog.removeAll()
    }

    func setVolume(_ volume: Double) {
        self.volumes.append(volume)
    }

    func showAirPlayPicker() {}

    var captionTracks: [YouTubeCaptionTrack] = []
    var quality: [String] = []
    private(set) var selectedCaption: String??
    private(set) var selectedQuality: String?

    func availableCaptionTracks() async -> [YouTubeCaptionTrack] {
        self.captionTracks
    }

    var activeCaption: String?

    func currentCaptionLanguageCode() async -> String? {
        self.activeCaption
    }

    func setCaptionTrack(languageCode: String?) {
        self.selectedCaption = languageCode
    }

    func availableQualityLevels() async -> [String] {
        self.quality
    }

    func currentQualityLevel() async -> String? {
        self.quality.first
    }

    func setQualityLevel(_ level: String) {
        self.selectedQuality = level
    }

    var storyboardSpecResponse: String?
    private(set) var storyboardSpecRequests: [String?] = []

    func storyboardSpec(expectedVideoId: String?) async -> String? {
        self.storyboardSpecRequests.append(expectedVideoId)
        return self.storyboardSpecResponse
    }

    func tearDown() {
        self.tearDownCount += 1
    }
}

// MARK: - BooleanBox

@MainActor
private final class BooleanBox {
    var value: Bool

    init(_ value: Bool) {
        self.value = value
    }
}

// MARK: - YouTubePlayerServiceTests

@Suite("YouTubePlayerService", .serialized, .tags(.service), .timeLimit(.minutes(1)))
@MainActor
struct YouTubePlayerServiceTests {
    private let controller: MockYouTubeWatchPlaybackController
    private let sut: YouTubePlayerService

    init() {
        self.controller = MockYouTubeWatchPlaybackController()
        // Pin the navigate-away pop-out gate ON so the existing pop-out
        // assertions don't depend on the global SettingsManager.shared state.
        self.sut = YouTubePlayerService(
            playbackController: self.controller,
            shouldPopOutOnNavigateAway: { true }
        )
    }

    @Test("Initial state is empty")
    func initialState() {
        #expect(self.sut.currentVideo == nil)
        #expect(self.sut.isPlaying == false)
        #expect(self.sut.surfaceLocation == .none)
    }

    @Test("Play loads the video docked inline and signals the arbiter")
    func playLoadsInline() {
        var willStartCount = 0
        self.sut.playbackWillStart = { willStartCount += 1 }

        let video = MockYouTubeClient.makeVideo(videoId: "abc")
        self.sut.play(video: video)

        #expect(self.sut.currentVideo?.videoId == "abc")
        #expect(self.sut.surfaceLocation == .inline)
        #expect(self.controller.prepareCount == 1)
        #expect(self.controller.loadedVideoIds == ["abc"])
        #expect(willStartCount == 1)
    }

    @Test("Identity-switch re-points the current video via a forced reload")
    func reloadForIdentitySwitchRepointsCurrentVideo() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(isPlaying: true, progress: 0, duration: 60, videoId: "abc"))

        self.sut.reloadCurrentVideoForIdentitySwitch()

        // A forced reload (not a plain loadVideo, which would no-op on same id).
        #expect(self.controller.reloadedVideoIds == ["abc"])
        // No progress yet → no resume seek requested.
        #expect(self.controller.reloadResumeSeconds == [nil])
    }

    @Test("Identity-switch is a no-op when no video is playing")
    func reloadForIdentitySwitchNoOpWhenIdle() {
        self.sut.reloadCurrentVideoForIdentitySwitch()
        #expect(self.controller.reloadedVideoIds.isEmpty)
    }

    @Test("Identity-switch during an ad resumes the content, not the ad position")
    func reloadDuringAdUsesContentProgress() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        // Content reaches 600s...
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 600,
            duration: 1200,
            hasReadyMedia: true,
            videoId: "abc",
            boundVideoId: "abc"
        ))
        // ...then a midroll ad starts, dragging self.progress down to the ad time.
        self.sut.updatePlaybackState(.init(isPlaying: true, progress: 8, duration: 30, videoId: "abc", isAd: true))
        #expect(self.sut.progress == 8)

        // A switch mid-ad must resume at the last CONTENT position (600), not 8.
        self.sut.reloadCurrentVideoForIdentitySwitch()
        #expect(self.controller.reloadResumeSeconds.last == .some(600))
    }

    @Test("Paused video identity reload is deferred until resume")
    func pausedReloadDefersUntilResume() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(isPlaying: false, progress: 12, duration: 60, videoId: "abc"))
        self.sut.pause()
        #expect(self.sut.isPlaying == false)
        let pausesBefore = self.controller.pauseCount
        var willStartCount = 0
        self.sut.playbackWillStart = { willStartCount += 1 }

        self.sut.reloadCurrentVideoForIdentitySwitch()

        // No autoplaying watch page is loaded while the user left the video paused.
        #expect(self.controller.reloadedVideoIds.isEmpty)
        #expect(self.controller.pauseCount == pausesBefore)
        #expect(self.sut.isPlaying == false)
        #expect(willStartCount == 0)

        self.sut.seek(to: 34)
        // User intent to resume performs the identity reload at the saved position.
        self.sut.resume()
        #expect(self.controller.reloadedVideoIds == ["abc"])
        #expect(self.controller.reloadResumeSeconds == [34])
        #expect(self.controller.playCount == 0)
        #expect(willStartCount == 1)
    }

    @Test("Relative video seeks move by 30 seconds and clamp backward to start")
    func relativeSeeksClampToBounds() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))

        self.sut.updatePlaybackState(.init(isPlaying: true, progress: 20, duration: 100, videoId: "abc"))
        self.sut.seekBackward()
        #expect(self.sut.progress == 0)
        #expect(self.controller.seeks == [0])

        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "def"))
        self.sut.updatePlaybackState(.init(isPlaying: true, progress: 45, duration: 100, videoId: "def"))
        self.sut.seekBackward()
        self.sut.seekForward()
        #expect(self.controller.seeks == [0, 15, 45])
    }

    @Test("Rapid relative seeks accumulate from the last requested target")
    func relativeSeeksAccumulateAcrossStaleObserverUpdates() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(isPlaying: true, progress: 10, duration: 100, videoId: "abc"))

        self.sut.seekForward()
        // A stale observer tick reports the pre-seek position before the next
        // button press. The second seek must build from 40, not from 10.
        self.sut.updatePlaybackState(.init(isPlaying: true, progress: 10, duration: 100, videoId: "abc"))
        self.sut.seekForward()

        #expect(self.sut.progress == 70)
        #expect(self.controller.seeks == [40, 70])
    }

    @Test("Forward relative seek near the end manually concludes without exact-duration seek")
    func relativeSeekToEndConcludesWithoutExactDurationSeek() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(isPlaying: true, progress: 90, duration: 100, videoId: "abc"))
        self.controller.replacePendingRecoverySeek(with: 12)
        self.controller.resetCommandLog()
        self.controller.onSeek = { _ in
            self.sut.updatePlaybackState(.init(
                isPlaying: true,
                progress: 100,
                duration: 100,
                videoId: "abc"
            ))
        }
        var endedVideoId: String?
        self.sut.onVideoEnded = { endedVideoId = $0 }
        let activityBefore = self.sut.watchActivityGeneration
        let conclusionBefore = self.sut.watchConclusionGeneration

        self.sut.seekForward()

        #expect(self.sut.progress == 100)
        #expect(self.sut.isPlaying == false)
        #expect(endedVideoId == "abc")
        #expect(self.sut.watchActivityGeneration == activityBefore + 1)
        #expect(self.sut.watchConclusionGeneration == conclusionBefore + 1)
        #expect(self.controller.cancelPendingRecoverySeekCount == 1)
        #expect(self.controller.markCurrentPlaybackOccurrenceEndedCount == 1)
        #expect(self.controller.commandLog.first == "cancelPendingRecoverySeek")
        #expect(self.controller.commandLog.dropFirst().first == "markCurrentPlaybackOccurrenceEnded")
        #expect(self.controller.commandLog.dropFirst(2).first == "seek")
        // The re-entrant playing update emitted from seek() is suppressed before
        // the terminal command's own pause, proving the native fence was active.
        #expect(self.controller.pauseCount == 2)
        #expect(self.controller.seeks.count == 1)
        #expect(self.controller.seeks[0] < 100)
        #expect(self.controller.seeks[0] >= 99)
    }

    @Test("Deferred paused identity reload survives observer updates before resume")
    func deferredPausedReloadSurvivesObserverUpdatesBeforeResume() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(isPlaying: false, progress: 3, duration: 60, videoId: "abc"))
        self.sut.pause()
        var willStartCount = 0
        self.sut.playbackWillStart = { willStartCount += 1 }

        self.sut.reloadCurrentVideoForIdentitySwitch()

        // Stray observer updates from the old paused page do not consume the
        // deferred identity reload. The reload still happens on explicit resume.
        self.sut.updatePlaybackState(.init(isPlaying: false, progress: 3, duration: 60, videoId: "abc"))
        #expect(self.controller.reloadedVideoIds.isEmpty)
        #expect(willStartCount == 0)

        self.sut.playPause()
        #expect(self.controller.reloadedVideoIds == ["abc"])
        #expect(self.controller.playPauseCount == 0)
        #expect(willStartCount == 1)
    }

    @Test("The first accepted update completes an identity reload")
    func acceptedUpdateCompletesIdentityReload() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 12,
            duration: 60,
            videoId: "abc"
        ))
        self.sut.reloadCurrentVideoForIdentitySwitch()

        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 12,
            duration: 60,
            videoId: "abc"
        ))
        self.sut.pause()
        self.sut.resume()

        #expect(self.controller.reloadedVideoIds == ["abc"])
        #expect(self.controller.playCount == 1)
    }

    @Test("A paused completed identity reload does not reload again on resume")
    func pausedCompletedIdentityReloadDoesNotRepeat() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 12,
            duration: 60,
            videoId: "abc"
        ))
        self.sut.reloadCurrentVideoForIdentitySwitch()
        self.sut.pause()

        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 12,
            duration: 60,
            hasReadyMedia: true,
            videoId: "abc"
        ))
        self.sut.resume()

        #expect(self.controller.reloadedVideoIds == ["abc"])
        #expect(self.controller.playCount == 1)
    }

    @Test("An explicit pause at zero defers identity recovery until resume")
    func pauseAtZeroDefersIdentityRecovery() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.pause()

        self.sut.reloadCurrentVideoForIdentitySwitch()

        #expect(self.controller.reloadedVideoIds.isEmpty)
        #expect(self.sut.pendingPausedIdentityReloadVideoId == "abc")
        #expect(self.sut.pendingPausedIdentityReloadResumeAt == nil)

        self.sut.resume()

        #expect(self.controller.reloadedVideoIds == ["abc"])
        #expect(self.controller.reloadResumeSeconds == [nil])
    }

    @Test("Loading video identity reload happens immediately")
    func loadingIdentityReloadHappensImmediately() {
        // A just-requested video has not reported playing yet, so isPlaying is
        // false but it is not a user-paused watch. If identity verification lands
        // in that loading window, the reload must happen immediately before the
        // old-identity page can start and emit watch-history pings.
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 0,
            duration: 60,
            videoId: "abc"
        ))
        var willStartCount = 0
        self.sut.playbackWillStart = { willStartCount += 1 }

        self.sut.reloadCurrentVideoForIdentitySwitch()

        #expect(self.controller.reloadedVideoIds == ["abc"])
        #expect(self.controller.reloadResumeSeconds == [nil])
        #expect(willStartCount == 0)
    }

    @Test("Deferred paused identity reload is cleared by a new video")
    func deferredPausedReloadClearsOnNewVideo() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(isPlaying: false, progress: 3, duration: 60, videoId: "abc"))
        self.sut.pause()
        self.sut.reloadCurrentVideoForIdentitySwitch()

        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "def"))
        self.sut.resume()

        #expect(self.controller.reloadedVideoIds.isEmpty)
        #expect(self.controller.loadedVideoIds == ["abc", "def"])
    }

    @Test("Playing video reloaded for identity switch keeps playing")
    func playingReloadDoesNotSuppress() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        // Establish a playing state first.
        self.sut.updatePlaybackState(.init(isPlaying: true, progress: 1, duration: 60, videoId: "abc"))
        #expect(self.sut.isPlaying == true)
        let pausesBefore = self.controller.pauseCount

        self.sut.reloadCurrentVideoForIdentitySwitch()
        self.sut.updatePlaybackState(.init(isPlaying: true, progress: 1, duration: 60, videoId: "abc"))

        // No suppression: a playing video stays playing across the reload.
        #expect(self.controller.pauseCount == pausesBefore)
        #expect(self.sut.isPlaying == true)
    }

    @Test("State updates from the bridge are applied")
    func stateUpdates() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))

        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 12.5, duration: 120,
            videoId: "abc", title: nil, isAd: false
        ))

        #expect(self.sut.isPlaying)
        #expect(self.sut.progress == 12.5)
        #expect(self.sut.duration == 120)
        #expect(self.sut.isShowingAd == false)
    }

    @Test("Bridge playback start signals the arbiter (covers SPA autostart)")
    func bridgeStartSignalsArbiter() {
        var willStartCount = 0
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.playbackWillStart = { willStartCount += 1 }

        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 0, duration: 10,
            videoId: "abc", title: nil, isAd: false
        ))
        // Second update while already playing must not re-signal.
        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 1, duration: 10,
            videoId: "abc", title: nil, isAd: false
        ))

        #expect(willStartCount == 1)
    }

    @Test("Follows SPA drift to a different video")
    func followsDrift() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))

        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 0, duration: 60,
            videoId: "xyz", title: "Drifted Title", isAd: false
        ))

        #expect(self.sut.currentVideo?.videoId == "xyz")
        #expect(self.sut.currentVideo?.title == "Drifted Title")
    }

    @Test("Inline disappearance while playing pops out to the floating window")
    func disappearWhilePlayingPopsOut() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.activeInlineVideoId = "abc"
        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 0, duration: 10,
            videoId: "abc", title: nil, isAd: false
        ))

        self.sut.inlineSurfaceWillDisappear(videoId: "abc")

        #expect(self.sut.surfaceLocation == .floating)
        #expect(self.sut.currentVideo != nil)
    }

    @Test("Inline disappearance while paused stops playback")
    func disappearWhilePausedStops() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.activeInlineVideoId = "abc"

        self.sut.inlineSurfaceWillDisappear(videoId: "abc")

        #expect(self.sut.surfaceLocation == .none)
        #expect(self.sut.currentVideo == nil)
        #expect(self.controller.tearDownCount == 1)
    }

    @Test("Disappearance of a non-owning view is ignored")
    func disappearOfOtherViewIgnored() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.activeInlineVideoId = "abc"

        // A different watch view (e.g. the previous one in the stack) goes away.
        self.sut.inlineSurfaceWillDisappear(videoId: "other")

        #expect(self.sut.surfaceLocation == .inline)
        #expect(self.sut.activeInlineVideoId == "abc")
    }

    @Test("Pop-out disabled: inline disappearance while playing stops instead of floating")
    func disappearWhilePlayingStopsWhenPopOutDisabled() {
        let controller = MockYouTubeWatchPlaybackController()
        let sut = YouTubePlayerService(
            playbackController: controller,
            shouldPopOutOnNavigateAway: { false }
        )
        sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        sut.activeInlineVideoId = "abc"
        sut.updatePlaybackState(.init(
            isPlaying: true, progress: 0, duration: 10,
            videoId: "abc", title: nil, isAd: false
        ))

        sut.inlineSurfaceWillDisappear(videoId: "abc")

        #expect(sut.surfaceLocation == .none)
        #expect(sut.currentVideo == nil)
        #expect(controller.tearDownCount == 1)
    }

    @Test("Pop-out disabled still yields to the one-shot source-switch suppression")
    func sourceSwitchStillPausesInPlaceWhenPopOutDisabled() {
        let controller = MockYouTubeWatchPlaybackController()
        let sut = YouTubePlayerService(
            playbackController: controller,
            shouldPopOutOnNavigateAway: { false }
        )
        sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        sut.activeInlineVideoId = "abc"
        sut.updatePlaybackState(.init(
            isPlaying: true, progress: 5, duration: 60,
            videoId: "abc", title: nil, isAd: false
        ))

        sut.prepareForSourceSwitch()
        sut.inlineSurfaceWillDisappear(videoId: "abc")

        // Suppression wins regardless of the setting: paused in place, not stopped.
        #expect(controller.pauseCount == 1)
        #expect(sut.surfaceLocation == .inline)
        #expect(sut.currentVideo?.videoId == "abc")
        #expect(controller.tearDownCount == 0)
    }

    @Test("Pop-out gate is read live, not captured at init")
    func popOutGateReadLive() {
        let controller = MockYouTubeWatchPlaybackController()
        let popOutEnabled = BooleanBox(false)
        let sut = YouTubePlayerService(
            playbackController: controller,
            shouldPopOutOnNavigateAway: { popOutEnabled.value }
        )

        // First navigate-away with the gate off: stops.
        sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        sut.activeInlineVideoId = "abc"
        sut.updatePlaybackState(.init(
            isPlaying: true, progress: 0, duration: 10,
            videoId: "abc", title: nil, isAd: false
        ))
        sut.inlineSurfaceWillDisappear(videoId: "abc")
        #expect(sut.surfaceLocation == .none)

        // Flip the gate on; a fresh playback now pops out.
        popOutEnabled.value = true
        sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        sut.activeInlineVideoId = "abc"
        sut.updatePlaybackState(.init(
            isPlaying: true, progress: 0, duration: 10,
            videoId: "abc", title: nil, isAd: false
        ))
        sut.inlineSurfaceWillDisappear(videoId: "abc")
        #expect(sut.surfaceLocation == .floating)
    }

    @Test("Video ended invokes the hook and clears isPlaying")
    func videoEnded() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 9, duration: 10,
            videoId: "abc", title: nil, isAd: false
        ))
        var endedVideoId: String?
        self.sut.onVideoEnded = { endedVideoId = $0 }

        let didAcceptEnd = self.sut.handleVideoEnded(videoId: "abc")

        #expect(self.sut.isPlaying == false)
        #expect(endedVideoId == "abc")
        #expect(didAcceptEnd)
    }

    @Test("Duplicate ended callbacks run one-shot effects once and later autoplay can end")
    func duplicateEndedCallbacksAreIdempotentPerWatch() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 59, duration: 60,
            videoId: "a", title: nil, isAd: false
        ))
        var endedVideoIds: [String?] = []
        self.sut.onVideoEnded = { endedVideoIds.append($0) }

        self.sut.handleVideoEnded(videoId: "a")
        self.sut.handleVideoEnded(videoId: "a")

        #expect(endedVideoIds == ["a"])

        // A genuine same-document autoplay drift starts a new watch occurrence.
        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 1, duration: 80,
            hasReadyMedia: true, videoId: "b", boundVideoId: "b",
            title: "Autoplay", isAd: false
        ))
        self.sut.handleVideoEnded(videoId: "b")

        #expect(endedVideoIds == ["a", "b"])
    }

    @Test("A queued ended occurrence cannot conclude a newer same-document replay")
    func staleEndedOccurrenceCannotConcludeReplay() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        let firstOccurrence = YouTubePlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 1
        )
        let replayOccurrence = YouTubePlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 2
        )
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 9,
            duration: 10,
            videoId: "a",
            playbackOccurrence: firstOccurrence
        ))
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 1,
            duration: 10,
            videoId: "a",
            playbackOccurrence: replayOccurrence
        ))
        var endedCount = 0
        self.sut.onVideoEnded = { _ in endedCount += 1 }

        self.sut.handleVideoEnded(
            videoId: "a",
            playbackOccurrence: firstOccurrence
        )

        #expect(self.sut.isPlaying)
        #expect(endedCount == 0)

        self.sut.handleVideoEnded(
            videoId: "a",
            playbackOccurrence: replayOccurrence
        )

        #expect(!self.sut.isPlaying)
        #expect(endedCount == 1)
    }

    @Test("A native terminal transition consumes the current bridge occurrence")
    func nativeEndConsumesCurrentBridgeOccurrence() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        let occurrence = YouTubePlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 1
        )
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 9,
            duration: 10,
            videoId: "a",
            playbackOccurrence: occurrence
        ))

        #expect(self.sut.handleVideoEnded(videoId: "a"))
        #expect(!self.sut.handleVideoEnded(
            videoId: "a",
            playbackOccurrence: occurrence
        ))
    }

    @Test("A delayed end cannot overwrite a newer resume intent")
    func delayedEndDoesNotOverwriteResume() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        let endedOccurrence = YouTubePlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 1
        )
        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 9.8,
            duration: 10,
            hasReadyMedia: true,
            videoId: "a",
            playbackOccurrence: endedOccurrence
        ))

        self.sut.resume()
        #expect(!self.sut.handleVideoEnded(
            videoId: "a",
            playbackOccurrence: endedOccurrence,
            eventIssuedAtMilliseconds: 0
        ))

        let replayOccurrence = YouTubePlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 2
        )
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 0,
            duration: 10,
            hasReadyMedia: true,
            videoId: "a",
            playbackOccurrence: replayOccurrence
        ))
        #expect(self.sut.handleVideoEnded(
            videoId: "a",
            playbackOccurrence: replayOccurrence
        ))
    }

    @Test("A normal pause and resume still accepts the eventual end")
    func normalResumeDoesNotSuppressEnd() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        let occurrence = YouTubePlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 1
        )
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 5,
            duration: 10,
            videoId: "a",
            playbackOccurrence: occurrence
        ))
        self.sut.pause()
        self.sut.resume()

        #expect(self.sut.handleVideoEnded(
            videoId: "a",
            playbackOccurrence: occurrence
        ))
    }

    @Test("A newer ended occurrence can bind before its first state update")
    func newerEndedOccurrenceCanBindFirst() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        let firstOccurrence = YouTubePlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 1
        )
        let replacementOccurrence = YouTubePlaybackOccurrence(
            documentGeneration: 8,
            mediaGeneration: 1
        )
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 9,
            duration: 10,
            videoId: "a",
            playbackOccurrence: firstOccurrence
        ))
        var endedCount = 0
        self.sut.onVideoEnded = { _ in endedCount += 1 }
        self.sut.handleVideoEnded(
            videoId: "a",
            playbackOccurrence: firstOccurrence
        )
        #expect(endedCount == 1)

        self.sut.handleVideoEnded(
            videoId: "a",
            playbackOccurrence: replacementOccurrence
        )

        #expect(!self.sut.isPlaying)
        #expect(endedCount == 2)
        #expect(self.sut.currentPlaybackOccurrence == replacementOccurrence)

        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 1,
            duration: 10,
            videoId: "a",
            playbackOccurrence: replacementOccurrence
        ))
        #expect(!self.sut.isPlaying)
    }

    @Test("A stale ended event for a no-longer-current video does not conclude the new watch")
    func endedEventForStaleVideoIdIgnored() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        // The page drifts to "b" (now the current watch).
        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 3, duration: 60,
            videoId: "b", title: "B", isAd: false
        ))
        #expect(self.sut.currentVideo?.videoId == "b")
        let conclusionBefore = self.sut.watchConclusionGeneration

        // A late VIDEO_ENDED for the previous video "a" arrives — it must be
        // ignored so it doesn't conclude (and dedupe) the current watch of "b".
        let didAcceptStaleEnd = self.sut.handleVideoEnded(videoId: "a")
        #expect(self.sut.watchConclusionGeneration == conclusionBefore)
        #expect(!didAcceptStaleEnd)

        // The real end of "b" still concludes it.
        self.sut.handleVideoEnded(videoId: "b")
        #expect(self.sut.watchConclusionGeneration == conclusionBefore + 1)
    }

    @Test("An ended event while an ad is showing does not conclude the watch")
    func endedEventDuringAdIgnored() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        // An ad is playing (last STATE_UPDATE set isShowingAd).
        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 2, duration: 15,
            videoId: "a", title: nil, isAd: true
        ))
        #expect(self.sut.isShowingAd)
        let conclusionBefore = self.sut.watchConclusionGeneration

        // The ad element fires VIDEO_ENDED — must NOT conclude the content watch.
        self.sut.handleVideoEnded(videoId: "a")
        #expect(self.sut.watchConclusionGeneration == conclusionBefore)

        // Once the real content plays and ends, it concludes normally.
        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 100, duration: 120,
            videoId: "a", title: nil, isAd: false
        ))
        self.sut.handleVideoEnded(videoId: "a")
        #expect(self.sut.watchConclusionGeneration == conclusionBefore + 1)
    }

    @Test("A post-roll ad cannot revive a concluded watch")
    func postRollAdDoesNotReviveConcludedWatch() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        let contentOccurrence = YouTubePlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 1
        )
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 59,
            duration: 60,
            videoId: "a",
            playbackOccurrence: contentOccurrence
        ))
        self.sut.handleVideoEnded(
            videoId: "a",
            playbackOccurrence: contentOccurrence
        )
        var playbackStartCount = 0
        self.sut.playbackWillStart = { playbackStartCount += 1 }

        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 1,
            duration: 15,
            hasReadyMedia: true,
            videoId: "a",
            isAd: true,
            playbackOccurrence: YouTubePlaybackOccurrence(
                documentGeneration: 7,
                mediaGeneration: 2
            )
        ))

        #expect(self.sut.isPlaying)
        #expect(self.controller.pauseCount == 0)
        #expect(playbackStartCount == 1)

        self.sut.playPause()
        #expect(self.controller.pauseCount == 1)
        #expect(self.controller.playCount == 0)
    }

    @Test("An end before resume confirmation replays on the first toggle")
    func endClearsResumeConfirmation() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        self.sut.resume()
        self.sut.handleVideoEnded(videoId: "a")

        self.sut.playPause()

        #expect(self.controller.pauseCount == 0)
        #expect(self.controller.playCount == 2)
    }

    @Test("A newer video's preroll ad can establish autoplay intent")
    func nextVideoPrerollCanStart() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        let firstOccurrence = YouTubePlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 1
        )
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 59,
            duration: 60,
            videoId: "a",
            boundVideoId: "a",
            playbackOccurrence: firstOccurrence
        ))
        self.sut.handleVideoEnded(
            videoId: "a",
            playbackOccurrence: firstOccurrence
        )

        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 0,
            duration: 15,
            hasReadyMedia: true,
            videoId: "b",
            boundVideoId: "b",
            title: "B",
            isAd: true,
            playbackOccurrence: YouTubePlaybackOccurrence(
                documentGeneration: 7,
                mediaGeneration: 2
            )
        ))

        #expect(self.sut.isPlaying)
        #expect(self.sut.currentVideo?.videoId == "a")
        #expect(self.controller.pauseCount == 0)

        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 1,
            duration: 80,
            hasReadyMedia: true,
            videoId: "b",
            boundVideoId: "b",
            title: "B",
            isAd: false,
            playbackOccurrence: YouTubePlaybackOccurrence(
                documentGeneration: 7,
                mediaGeneration: 2
            )
        ))
        #expect(self.sut.currentVideo?.videoId == "b")
    }
}

extension YouTubePlayerServiceTests {
    @Test("Non-authoritative post-roll placeholders survive process termination")
    func loadingPostRollPlaceholderTerminationRecoversNextVideo() {
        for isAd in [true, false] {
            let controller = MockYouTubeWatchPlaybackController()
            let sut = YouTubePlayerService(playbackController: controller)
            let nextVideo = MockYouTubeClient.makeVideo(videoId: "b")
            sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
            sut.setUpNext([nextVideo])
            let contentOccurrence = YouTubePlaybackOccurrence(
                documentGeneration: 7,
                mediaGeneration: 1
            )
            sut.updatePlaybackState(.init(
                isPlaying: true,
                progress: 59,
                duration: 60,
                hasReadyMedia: true,
                videoId: "a",
                boundVideoId: "a",
                playbackOccurrence: contentOccurrence
            ))
            sut.handleVideoEnded(
                videoId: "a",
                playbackOccurrence: contentOccurrence
            )

            sut.updatePlaybackState(.init(
                isPlaying: false,
                progress: 0,
                duration: 0,
                hasReadyMedia: false,
                videoId: "b",
                boundVideoId: "a",
                isAd: isAd,
                playbackOccurrence: contentOccurrence
            ))

            #expect(sut.currentVideo?.videoId == "a")

            sut.recoverAfterWebContentProcessTermination()

            #expect(sut.currentVideo?.videoId == "a")
            #expect(controller.reloadedVideoIds.isEmpty)

            sut.resume()

            #expect(sut.currentVideo?.videoId == "b")
            #expect(controller.loadedVideoIds == ["a", "b"])
            #expect(controller.reloadedVideoIds.isEmpty)
        }
    }

    @Test("Explicit replay placeholders recover the concluded video")
    func explicitReplayPlaceholderTerminationReloadsCurrentVideo() {
        for isAd in [true, false] {
            let controller = MockYouTubeWatchPlaybackController()
            let sut = YouTubePlayerService(playbackController: controller)
            sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
            sut.setUpNext([MockYouTubeClient.makeVideo(videoId: "b")])
            let contentOccurrence = YouTubePlaybackOccurrence(
                documentGeneration: 7,
                mediaGeneration: 1
            )
            sut.updatePlaybackState(.init(
                isPlaying: true,
                progress: 59,
                duration: 60,
                hasReadyMedia: true,
                videoId: "a",
                boundVideoId: "a",
                playbackOccurrence: contentOccurrence
            ))
            sut.handleVideoEnded(
                videoId: "a",
                playbackOccurrence: contentOccurrence
            )

            sut.resume()
            sut.updatePlaybackState(.init(
                isPlaying: false,
                progress: 0,
                duration: 0,
                hasReadyMedia: false,
                videoId: "a",
                boundVideoId: "a",
                isAd: isAd,
                playbackOccurrence: contentOccurrence
            ))
            sut.recoverAfterWebContentProcessTermination()

            #expect(sut.currentVideo?.videoId == "a")
            #expect(controller.reloadedVideoIds == ["a"])
            #expect(controller.loadedVideoIds == ["a"])
        }
    }

    @Test("A post-end user seek supersedes deferred autoplay recovery")
    func postEndSeekRecoversCurrentVideo() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        self.sut.setUpNext([MockYouTubeClient.makeVideo(videoId: "b")])
        let contentOccurrence = YouTubePlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 1
        )
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 59,
            duration: 60,
            hasReadyMedia: true,
            videoId: "a",
            boundVideoId: "a",
            playbackOccurrence: contentOccurrence
        ))
        self.sut.handleVideoEnded(
            videoId: "a",
            playbackOccurrence: contentOccurrence
        )
        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 0,
            duration: 0,
            hasReadyMedia: false,
            videoId: "b",
            boundVideoId: "a",
            playbackOccurrence: contentOccurrence
        ))

        self.sut.seek(to: 10)
        // A queued same-occurrence loading sample must not re-arm successor
        // recovery after the explicit seek has claimed the concluded video.
        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 0,
            duration: 0,
            hasReadyMedia: false,
            videoId: "b",
            boundVideoId: "a",
            playbackOccurrence: contentOccurrence
        ))
        self.sut.recoverAfterWebContentProcessTermination()

        #expect(self.sut.currentVideo?.videoId == "a")
        #expect(self.sut.pendingPausedIdentityReloadVideoId == "a")
        #expect(self.sut.pendingPausedIdentityReloadResumeAt == 10)

        self.sut.resume()

        #expect(self.controller.reloadedVideoIds == ["a"])
        #expect(self.controller.reloadResumeSeconds == [10])
        #expect(self.sut.currentVideo?.videoId == "a")
    }

    @Test("A canceled successor lookup remains retryable after explicit pause")
    func canceledAutoplayLookupRemainsRetryable() async {
        let firstLookupStarted = AsyncGate()
        let releaseFirstLookup = AsyncGate()
        let successorLoaded = BooleanBox(false)
        let nextVideo = MockYouTubeClient.makeVideo(videoId: "b")
        let client = MockYouTubeClient()
        client.watchNextData = WatchNextData(
            videoTitle: nil,
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [nextVideo]
        )
        client.beforeWatchNextReturnByCallCount = { callCount in
            guard callCount == 1 else { return }
            await firstLookupStarted.open()
            await releaseFirstLookup.wait()
        }
        self.sut.youtubeClient = client
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        self.controller.onLoadVideo = { videoId in
            guard videoId == "b" else { return }
            successorLoaded.value = true
        }
        let contentOccurrence = YouTubePlaybackOccurrence(
            documentGeneration: 7,
            mediaGeneration: 1
        )
        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 59,
            duration: 60,
            hasReadyMedia: true,
            videoId: "a",
            boundVideoId: "a",
            playbackOccurrence: contentOccurrence
        ))
        self.sut.handleVideoEnded(
            videoId: "a",
            playbackOccurrence: contentOccurrence
        )
        self.sut.updatePlaybackState(.init(
            isPlaying: false,
            progress: 0,
            duration: 0,
            hasReadyMedia: false,
            videoId: "creative",
            boundVideoId: "a",
            isAd: true,
            playbackOccurrence: YouTubePlaybackOccurrence(
                documentGeneration: 7,
                mediaGeneration: 2
            )
        ))
        self.sut.recoverAfterWebContentProcessTermination()

        self.sut.resume()
        await firstLookupStarted.wait()
        self.sut.playPause()
        self.sut.resume()
        await releaseFirstLookup.open()
        for _ in 0 ..< 10 where !successorLoaded.value {
            await Task.yield()
        }

        #expect(self.sut.currentVideo?.videoId == "b")
        #expect(successorLoaded.value)
        #expect(client.watchNextCallCount == 2)
        #expect(self.controller.loadedVideoIds == ["a", "b"])
        #expect(self.controller.playCount == 0)
    }

    @Test("Watch-activity generation advances on every watch-state change and survives stop")
    func watchActivityGenerationTracksEveryChange() async {
        #expect(self.sut.watchActivityGeneration == 0)
        #expect(self.sut.watchConclusionGeneration == 0)

        // Starting a video advances the ACTIVITY generation, but NOT the
        // CONCLUSION generation (a bare start has no accrued progress to reflect).
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        #expect(self.sut.watchActivityGeneration == 1)
        #expect(self.sut.watchConclusionGeneration == 0)

        // Skipping concludes one watch, begins another — advances BOTH.
        self.sut.setUpNext([MockYouTubeClient.makeVideo(videoId: "b")])
        await self.sut.skipForward()
        #expect(self.sut.currentVideo?.videoId == "b")
        #expect(self.sut.watchActivityGeneration == 2)
        #expect(self.sut.watchConclusionGeneration == 1)

        // SPA drift to a different video (autoplay/next) — advances BOTH.
        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 5, duration: 60,
            videoId: "c", title: "Drifted", isAd: false
        ))
        #expect(self.sut.currentVideo?.videoId == "c")
        #expect(self.sut.watchActivityGeneration == 3)
        #expect(self.sut.watchConclusionGeneration == 2)

        // A natural finish on a video that accrued real progress — advances BOTH.
        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 58, duration: 60,
            videoId: "c", title: nil, isAd: false
        ))
        self.sut.handleVideoEnded(videoId: "c")
        #expect(self.sut.watchActivityGeneration == 4)
        #expect(self.sut.watchConclusionGeneration == 3)

        // Closing the player after a finish (progress still nonzero, currentVideo
        // still set) must NOT re-signal the already-finished video as a fresh
        // conclusion — neither generation advances, and stop() doesn't reset them.
        self.sut.stop()
        #expect(self.sut.currentVideo == nil)
        #expect(self.sut.watchActivityGeneration == 4)
        #expect(self.sut.watchConclusionGeneration == 3)
    }

    @Test("Closing the window right after a finish does not double-signal the conclusion")
    func stopAfterFinishDoesNotDoubleSignal() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 119, duration: 120,
            videoId: "a", title: nil, isAd: false
        ))
        self.sut.handleVideoEnded(videoId: "a")
        let activityAfterFinish = self.sut.watchActivityGeneration
        let conclusionAfterFinish = self.sut.watchConclusionGeneration

        // The user closes the floating window; progress is still 119 and
        // currentVideo is still "a", but the finish already signalled.
        self.sut.stop()
        #expect(self.sut.watchActivityGeneration == activityAfterFinish)
        #expect(self.sut.watchConclusionGeneration == conclusionAfterFinish)
    }

    @Test("Auto-advance drift right after a finish does not double-signal the conclusion")
    func driftAfterFinishDoesNotDoubleConclude() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 119, duration: 120,
            videoId: "a", title: nil, isAd: false
        ))
        self.sut.handleVideoEnded(videoId: "a")
        let conclusionAfterFinish = self.sut.watchConclusionGeneration
        let activityAfterFinish = self.sut.watchActivityGeneration

        // The page auto-advances to the next video (playlist). The drift begins a
        // NEW watch (activity advances) but must NOT re-conclude the already
        // finished "a" (conclusion stays put).
        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 0, duration: 200,
            hasReadyMedia: true, videoId: "b", boundVideoId: "b",
            title: "Next", isAd: false
        ))
        #expect(self.sut.currentVideo?.videoId == "b")
        #expect(self.sut.watchConclusionGeneration == conclusionAfterFinish) // no double-conclude
        #expect(self.sut.watchActivityGeneration == activityAfterFinish + 1) // new watch began

        // The new video then concludes (e.g. finishes) — that DOES signal, since
        // it is a different, unconcluded watch.
        self.sut.handleVideoEnded(videoId: "b")
        #expect(self.sut.watchConclusionGeneration == conclusionAfterFinish + 1)
    }

    @Test("Replaying a finished video lets its later stop signal the new partial watch")
    func replayAfterFinishReSignalsOnStop() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 119, duration: 120,
            videoId: "a", title: nil, isAd: false
        ))
        self.sut.handleVideoEnded(videoId: "a") // finished → concluded
        let conclusionAfterFinish = self.sut.watchConclusionGeneration

        // The user replays the SAME video (seek back / play again): it's playing
        // with fresh progress, which clears the concluded flag.
        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 8, duration: 120,
            videoId: "a", title: nil, isAd: false
        ))

        // Closing after the partial rewatch must signal again (not be deduped),
        // so Home reflects the new resume position.
        self.sut.stop()
        #expect(self.sut.watchConclusionGeneration == conclusionAfterFinish + 1)
    }

    @Test("Stopping a video with accrued progress advances both generations")
    func stopWithProgressAdvancesGeneration() {
        // Closing the floating window or navigating away with pop-out disabled
        // both route through stop(); a partial watch must still signal Home — and
        // it is a CONCLUSION, so the Home-root observer's signal advances too.
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        #expect(self.sut.watchActivityGeneration == 1)
        #expect(self.sut.watchConclusionGeneration == 0)
        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 42, duration: 120,
            videoId: "a", title: nil, isAd: false
        ))

        self.sut.stop()
        #expect(self.sut.watchActivityGeneration == 2) // progress > 0 → signalled
        #expect(self.sut.watchConclusionGeneration == 1)
    }

    @Test("Stopping a video with no progress does not advance either generation")
    func stopWithoutProgressDoesNotAdvance() {
        // A video that never started playing (progress 0) has no resume state to
        // reflect, so closing it shouldn't trigger a redundant rail refresh.
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "a"))
        #expect(self.sut.watchActivityGeneration == 1)
        #expect(self.sut.watchConclusionGeneration == 0)

        self.sut.stop() // progress is still 0
        #expect(self.sut.watchActivityGeneration == 1)
        #expect(self.sut.watchConclusionGeneration == 0)
    }

    @Test("Volume changes forward to the playback controller")
    func volumeForwards() {
        self.sut.volume = 0.4
        #expect(self.controller.volumes == [0.4])
    }

    @Test("Like and dislike toggle through the client with reset on new video")
    func ratingToggles() async {
        let client = MockYouTubeClient()
        self.sut.youtubeClient = client
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))

        await self.sut.toggleLike()
        #expect(self.sut.currentRating == .like)

        await self.sut.toggleDislike()
        #expect(self.sut.currentRating == .dislike)

        await self.sut.toggleDislike()
        #expect(self.sut.currentRating == YouTubeRating.none)
        #expect(client.ratedVideos.map(\.videoId) == ["abc", "abc", "abc"])

        // A new video starts with no rating.
        await self.sut.toggleLike()
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "xyz"))
        #expect(self.sut.currentRating == YouTubeRating.none)
    }

    @Test("Rating failure rolls back the optimistic state")
    func ratingFailureRollsBack() async {
        let client = MockYouTubeClient()
        client.error = YTMusicError.authExpired
        self.sut.youtubeClient = client
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))

        await self.sut.toggleLike()

        #expect(self.sut.currentRating == YouTubeRating.none)
    }

    @Test("Skip forward plays the next up-next video and records history")
    func skipForwardUsesUpNext() async {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "first"))
        self.sut.setUpNext([
            MockYouTubeClient.makeVideo(videoId: "second"),
            MockYouTubeClient.makeVideo(videoId: "third"),
        ])

        await self.sut.skipForward()

        #expect(self.sut.currentVideo?.videoId == "second")
        #expect(self.controller.loadedVideoIds == ["first", "second"])
        // Inline surface: a navigation request opens the new watch view.
        #expect(self.sut.skipNavigationRequest?.videoId == "second")

        // Skip backward returns to the first video without re-recording it.
        self.sut.skipBackward()
        #expect(self.sut.currentVideo?.videoId == "first")
    }

    @Test("Skip forward fetches related lazily when no up-next is known")
    func skipForwardFetchesLazily() async {
        let client = MockYouTubeClient()
        client.watchNextData = WatchNextData(
            videoTitle: nil,
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [MockYouTubeClient.makeVideo(videoId: "fetched")]
        )
        self.sut.youtubeClient = client
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "first"))

        await self.sut.skipForward()

        #expect(self.sut.currentVideo?.videoId == "fetched")
    }

    @Test("Skip backward with no history restarts the video")
    func skipBackwardRestarts() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "only"))

        self.sut.skipBackward()

        #expect(self.sut.currentVideo?.videoId == "only")
        #expect(self.controller.seeks == [0])
    }

    @Test("Up-next filters out the current video and Shorts")
    func upNextFilters() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "current"))

        self.sut.setUpNext([
            MockYouTubeClient.makeVideo(videoId: "current"),
            YouTubeVideo(videoId: "a-short", title: "Short", isShort: true),
            MockYouTubeClient.makeVideo(videoId: "keeper"),
        ])

        #expect(self.sut.upNext.map(\.videoId) == ["keeper"])
    }

    @Test("Chapter markers filter to the current video")
    func chapterMarkersFilter() {
        self.sut.setChapters([
            YouTubeChapter(videoId: nil, title: "No current", startTime: 1, endTime: nil, timeText: nil, thumbnailURL: nil),
        ])
        #expect(self.sut.chapters.isEmpty)

        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "current"))

        self.sut.setChapters([
            YouTubeChapter(videoId: "current", title: "Matching", startTime: 10, endTime: nil, timeText: "0:10", thumbnailURL: nil),
            YouTubeChapter(videoId: "other", title: "Other", startTime: 20, endTime: nil, timeText: "0:20", thumbnailURL: nil),
            YouTubeChapter(videoId: nil, title: "Implicit", startTime: 30, endTime: nil, timeText: "0:30", thumbnailURL: nil),
        ])

        #expect(self.sut.chapters.map(\.title) == ["Matching", "Implicit"])
    }

    @Test("Play can start at a deferred seek position")
    func playWithStartPositionDefersSeekUntilLoad() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "chaptered"), startAt: 42)

        #expect(self.controller.loadedVideoIds.isEmpty)
        #expect(self.controller.reloadedVideoIds == ["chaptered"])
        #expect(self.controller.reloadResumeSeconds == [42])
        #expect(self.controller.seeks.isEmpty)
    }

    @Test("Play can start at an explicit zero seek position")
    func playWithZeroStartPositionDefersSeekUntilLoad() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "chaptered"), startAt: 0)

        #expect(self.controller.loadedVideoIds.isEmpty)
        #expect(self.controller.reloadedVideoIds == ["chaptered"])
        #expect(self.controller.reloadResumeSeconds == [0])
        #expect(self.controller.seeks.isEmpty)
    }

    @Test("Skipping while floating keeps the surface in the window")
    func skipWhileFloatingStaysFloating() async {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "first"))
        self.sut.popOutToWindow()
        self.sut.setUpNext([MockYouTubeClient.makeVideo(videoId: "second")])

        await self.sut.skipForward()

        #expect(self.sut.surfaceLocation == .floating)
        #expect(self.sut.skipNavigationRequest == nil)
    }

    @Test("Watch Later toggles through the client and resets per video")
    func watchLaterToggles() async {
        let client = MockYouTubeClient()
        self.sut.youtubeClient = client
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))

        await self.sut.toggleWatchLater()
        #expect(self.sut.isInWatchLater)
        #expect(client.watchLaterAdds == ["abc"])

        await self.sut.toggleWatchLater()
        #expect(self.sut.isInWatchLater == false)
        #expect(client.watchLaterRemovals == ["abc"])

        await self.sut.toggleWatchLater()
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "xyz"))
        #expect(self.sut.isInWatchLater == false)
    }

    @Test("Playback options load once per video and selections forward")
    func playbackOptions() async {
        self.controller.captionTracks = [
            YouTubeCaptionTrack(languageCode: "en", displayName: "English"),
        ]
        self.controller.quality = ["hd1080", "hd720", "auto"]
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))

        await self.sut.refreshPlaybackOptions()

        #expect(self.sut.captionTracks.count == 1)
        #expect(self.sut.qualityLevels == ["hd1080", "hd720", "auto"])

        self.sut.selectCaptionTrack(languageCode: "en")
        #expect(self.sut.activeCaptionLanguageCode == "en")
        #expect(self.controller.selectedCaption == "en")

        self.sut.selectQuality("hd720")
        #expect(self.sut.currentQuality == "hd720")
        #expect(self.controller.selectedQuality == "hd720")
    }

    @Test("Source switch pauses the docked video in place — no pop-out")
    func sourceSwitchPausesInPlace() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.activeInlineVideoId = "abc"
        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 5, duration: 60,
            videoId: "abc", title: nil, isAd: false
        ))

        self.sut.prepareForSourceSwitch()
        self.sut.inlineSurfaceWillDisappear(videoId: "abc")

        #expect(self.controller.pauseCount == 1)
        #expect(self.sut.surfaceLocation == .inline)
        #expect(self.sut.currentVideo?.videoId == "abc")
        #expect(self.controller.tearDownCount == 0)

        // The suppression is one-shot: a later in-app navigation while
        // playing pops out as usual.
        self.sut.updatePlaybackState(.init(
            isPlaying: false, progress: 5, duration: 60,
            videoId: "abc", title: nil, isAd: false
        ))
        self.sut.resume()
        self.sut.activeInlineVideoId = "abc"
        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 6, duration: 60,
            videoId: "abc", title: nil, isAd: false
        ))
        self.sut.inlineSurfaceWillDisappear(videoId: "abc")
        #expect(self.sut.surfaceLocation == .floating)
    }

    @Test("Pop-in request only fires from the floating window")
    func popInRequest() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))

        // Inline: no request.
        self.sut.requestPopIn()
        #expect(self.sut.popInRequest == nil)

        self.sut.popOutToWindow()
        self.sut.requestPopIn()
        #expect(self.sut.popInRequest?.videoId == "abc")

        self.sut.consumePopInRequest()
        #expect(self.sut.popInRequest == nil)
    }

    @Test("Storyboard refresh task starts once while in-flight and once resolved")
    func storyboardRefreshTaskStartIsGuarded() async throws {
        self.controller.storyboardSpecResponse = "mock-storyboard-spec"
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))

        #expect(self.sut.startStoryboardSpecRefreshIfNeeded())
        #expect(!self.sut.startStoryboardSpecRefreshIfNeeded())

        try await Task.sleep(for: .milliseconds(20))

        #expect(self.controller.storyboardSpecRequests == ["abc"])
        #expect(self.sut.storyboardSpec == "mock-storyboard-spec")
        #expect(!self.sut.startStoryboardSpecRefreshIfNeeded())
    }

    @Test("Playback tick skips storyboard refresh unless live ambient is active")
    func playbackTickSkipsStoryboardRefreshForSteadyAmbient() async throws {
        let settings = SettingsManager.shared
        let originalEnabled = settings.ambientBackdropEnabled
        let originalStyle = settings.ambientBackdropStyle
        defer {
            settings.ambientBackdropEnabled = originalEnabled
            settings.ambientBackdropStyle = originalStyle
        }

        settings.ambientBackdropEnabled = true
        settings.ambientBackdropStyle = .soft
        self.controller.storyboardSpecResponse = "mock-storyboard-spec"
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))

        self.sut.updatePlaybackState(.init(
            isPlaying: true,
            progress: 1,
            duration: 60,
            videoId: "abc",
            title: nil,
            isAd: false
        ))

        try await Task.sleep(for: .milliseconds(20))

        #expect(self.controller.storyboardSpecRequests.isEmpty)
        #expect(self.sut.storyboardSpec == nil)
    }

    @Test("Stop resets everything and tears down the WebView")
    func stopResets() {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        self.sut.updatePlaybackState(.init(
            isPlaying: true, progress: 5, duration: 10,
            videoId: "abc", title: nil, isAd: false
        ))

        self.sut.stop()

        #expect(self.sut.currentVideo == nil)
        #expect(self.sut.isPlaying == false)
        #expect(self.sut.progress == 0)
        #expect(self.sut.surfaceLocation == .none)
        #expect(self.controller.tearDownCount == 1)
    }

    @Test("An older ended callback cannot break a newer remote-command batch")
    func staleEndedCallbackPreservesRemoteBatch() {
        let controller = MockYouTubeWatchPlaybackController()
        let service = YouTubePlayerService(playbackController: controller)
        let video = MockYouTubeClient.makeVideo(videoId: "stale-ended-remote-batch")
        service.play(video: video)
        service.youtubePlaybackIntentIssuedAtMilliseconds = 1000

        service.handleRemotePause(issuedAtMilliseconds: 1600)
        #expect(!service.handleVideoEnded(
            videoId: video.videoId,
            eventIssuedAtMilliseconds: 1500
        ))
        service.handleRemoteResume(issuedAtMilliseconds: 1600)

        #expect(controller.pauseCount == 1)
        #expect(controller.playCount == 1)
    }

    @Test("A newer remote pause invalidates an older delayed skip")
    func remotePauseInvalidatesDelayedSkip() async {
        let controller = MockYouTubeWatchPlaybackController()
        let service = YouTubePlayerService(playbackController: controller)
        let client = MockYouTubeClient()
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        client.watchNextData = WatchNextData(
            videoTitle: nil,
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: [MockYouTubeClient.makeVideo(videoId: "stale-next")]
        )
        client.beforeWatchNextReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }
        service.youtubeClient = client
        service.play(video: MockYouTubeClient.makeVideo(videoId: "current"))

        let skipTask = Task { @MainActor in
            await service.skipForward()
        }
        await requestStarted.wait()
        service.handleRemotePause(
            issuedAtMilliseconds: service.youtubePlaybackIntentIssuedAtMilliseconds + 1
        )
        await releaseRequest.open()
        await skipTask.value

        #expect(service.currentVideo?.videoId == "current")
        #expect(controller.pauseCount == 1)
    }

    @Test("A remote command issued after an ended event remains admissible")
    func remoteCommandAfterEndedEventRemainsAdmissible() {
        let controller = MockYouTubeWatchPlaybackController()
        let service = YouTubePlayerService(playbackController: controller)
        let video = MockYouTubeClient.makeVideo(videoId: "ended-remote-order")
        service.play(video: video)
        service.youtubePlaybackIntentIssuedAtMilliseconds = 1000

        #expect(service.handleVideoEnded(
            videoId: video.videoId,
            eventIssuedAtMilliseconds: 1500
        ))
        service.handleRemoteResume(issuedAtMilliseconds: 1600)

        #expect(controller.playCount == 1)
    }

    @Test("Remote video commands captured before a newer native intent are ignored")
    func staleRemoteVideoCommandsAreIgnored() {
        let controller = MockYouTubeWatchPlaybackController()
        let service = YouTubePlayerService(playbackController: controller)
        service.beginYouTubePlaybackIntent(issuedAtMilliseconds: 2000)

        service.handleRemotePause(issuedAtMilliseconds: 1000)
        service.handleRemoteResume(issuedAtMilliseconds: 1000)
        service.handleRemoteSeek(to: 42, issuedAtMilliseconds: 1000)

        #expect(controller.pauseCount == 0)
        #expect(controller.playCount == 0)
        #expect(controller.pendingRecoverySeeks.isEmpty)

        service.handleRemotePause(issuedAtMilliseconds: 2001)
        service.handleRemoteResume(issuedAtMilliseconds: 2002)
        service.handleRemoteSeek(to: 42, issuedAtMilliseconds: 2003)

        #expect(controller.pauseCount == 1)
        #expect(controller.playCount == 1)
        #expect(controller.pendingRecoverySeeks == [42])
    }
}

// MARK: - PlaybackArbiterTests

@Suite("PlaybackArbiter", .serialized, .tags(.service), .timeLimit(.minutes(1)))
@MainActor
struct PlaybackArbiterTests {
    @Test("Video start claims the active source and pauses playing music")
    func videoStartPausesMusic() {
        let playerService = PlayerService()
        let controller = MockYouTubeWatchPlaybackController()
        let youtubePlayer = YouTubePlayerService(playbackController: controller)
        let arbiter = PlaybackArbiter(playerService: playerService, youtubePlayerService: youtubePlayer)

        #expect(arbiter.activeSource == .music)

        youtubePlayer.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))

        #expect(arbiter.activeSource == .video)
        #expect(arbiter.routesMediaKeysToVideo)
    }

    @Test("Music start pauses a playing video and reclaims routing")
    func musicStartPausesVideo() {
        let playerService = PlayerService()
        let controller = MockYouTubeWatchPlaybackController()
        let youtubePlayer = YouTubePlayerService(playbackController: controller)
        let arbiter = PlaybackArbiter(playerService: playerService, youtubePlayerService: youtubePlayer)

        youtubePlayer.play(video: MockYouTubeClient.makeVideo(videoId: "abc"))
        youtubePlayer.updatePlaybackState(.init(
            isPlaying: true, progress: 0, duration: 10,
            videoId: "abc", title: nil, isAd: false
        ))
        #expect(arbiter.activeSource == .video)

        arbiter.musicDidStartPlaying()

        #expect(arbiter.activeSource == .music)
        #expect(controller.pauseCount == 1)
        #expect(arbiter.routesMediaKeysToVideo == false)
    }

    @Test("Repeated music starts do not re-pause the video")
    func repeatedMusicStartsIdempotent() {
        let playerService = PlayerService()
        let controller = MockYouTubeWatchPlaybackController()
        let youtubePlayer = YouTubePlayerService(playbackController: controller)
        let arbiter = PlaybackArbiter(playerService: playerService, youtubePlayerService: youtubePlayer)

        arbiter.musicDidStartPlaying()
        arbiter.musicDidStartPlaying()

        #expect(controller.pauseCount == 0)
        #expect(arbiter.activeSource == .music)
    }

    @Test("A queued video pause cannot pause music that reclaimed playback")
    func staleVideoPauseDoesNotPauseNewMusicIntent() async {
        let playerService = PlayerService()
        let controller = MockYouTubeWatchPlaybackController()
        let youtubePlayer = YouTubePlayerService(playbackController: controller)
        let arbiter = PlaybackArbiter(playerService: playerService, youtubePlayerService: youtubePlayer)
        playerService.state = .playing

        arbiter.videoWillStartPlaying()
        await playerService.play(song: Song(
            id: "new",
            title: "New",
            artists: [],
            duration: 180,
            videoId: "new",
            feedbackTokens: .init(add: nil, remove: nil)
        ))
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        #expect(playerService.state == .loading)
        #expect(playerService.currentTrack?.videoId == "new")
    }

    @Test("Video ownership supersedes a pending Music API intent")
    func videoSupersedesPendingMusicIntent() async {
        let playerService = PlayerService()
        let musicClient = MockYTMusicClient()
        playerService.setYTMusicClient(musicClient)
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        musicClient.mixQueueResult = RadioQueueResult(
            songs: [Song(id: "stale", title: "Stale", artists: [], videoId: "stale")],
            continuationToken: nil
        )
        musicClient.beforeMixQueueReturn = { _, _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }
        let controller = MockYouTubeWatchPlaybackController()
        let youtubePlayer = YouTubePlayerService(playbackController: controller)
        let arbiter = PlaybackArbiter(playerService: playerService, youtubePlayerService: youtubePlayer)

        let mixTask = Task { @MainActor in
            await playerService.playWithMix(playlistId: "RDEM-stale", startVideoId: nil)
        }
        await requestStarted.wait()
        arbiter.videoWillStartPlaying()
        await releaseRequest.open()
        await mixTask.value

        #expect(arbiter.activeSource == .video)
        #expect(playerService.queue.isEmpty)
        #expect(playerService.currentTrack == nil)
    }
}
