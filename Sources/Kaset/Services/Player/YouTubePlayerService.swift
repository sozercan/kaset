import Foundation
import Observation

// MARK: - YouTubeWatchPlaybackControlling

/// Playback command surface backing `YouTubePlayerService`.
/// The real implementation is `YouTubeWatchWebView`; tests inject a recorder.
@MainActor
protocol YouTubeWatchPlaybackControlling: AnyObject {
    func prepare(webKitManager: WebKitManager, playerService: YouTubePlayerService)
    func loadVideo(videoId: String)
    func playPause()
    func play()
    func pause()
    func seek(to time: Double)
    func setVolume(_ volume: Double)
    func showAirPlayPicker()
    func availableCaptionTracks() async -> [YouTubeCaptionTrack]
    func currentCaptionLanguageCode() async -> String?
    func setCaptionTrack(languageCode: String?)
    func availableQualityLevels() async -> [String]
    func currentQualityLevel() async -> String?
    func setQualityLevel(_ level: String)
    func storyboardSpec(expectedVideoId: String?) async -> String?
    func tearDown()
}

// MARK: - YouTubeWatchWebView + YouTubeWatchPlaybackControlling

extension YouTubeWatchWebView: YouTubeWatchPlaybackControlling {
    func prepare(webKitManager: WebKitManager, playerService: YouTubePlayerService) {
        _ = self.getWebView(webKitManager: webKitManager, playerService: playerService)
    }
}

// MARK: - YouTubePlayerService

/// Playback state and control for regular YouTube videos.
///
/// Parallel to `PlayerService` (music) — that service is untouched. The
/// actual playback happens in `YouTubeWatchWebView`; this service owns the
/// observable state, command surface, and the docked/floating placement of
/// the extracted video surface.
@MainActor
@Observable
final class YouTubePlayerService {
    // MARK: - State

    /// The video currently loaded for playback (nil when playback is closed).
    private(set) var currentVideo: YouTubeVideo?

    /// Monotonic generation bumped by EVERY change to what/how-much was watched:
    /// a video starting (`play`), a skip to another (`advance`), a finish
    /// (`handleVideoEnded`), the page drifting to a different video
    /// (`updatePlaybackState`), and `stop()` tearing down a video that had
    /// accrued progress. It is a pure SIGNAL — set-only here, never consumed by
    /// readers. Home keeps its OWN watermark of the last generation it reflected
    /// and rebuilds Continue Watching whenever this is ahead of that watermark.
    ///
    /// Deliberately over-signals: a redundant rebuild is cheap and correct, while
    /// a missed signal leaves the rail stale. This inverts the old fragile model
    /// (multiple counters, eagerly consumed at the wrong moment) where every new
    /// watch path needed a matching "remember to bump / don't consume early" fix.
    private(set) var watchActivityGeneration = 0

    /// Like `watchActivityGeneration` but bumped only when a watch CONCLUDES with
    /// progress to reflect — a skip (`advance`), finish (`handleVideoEnded`),
    /// drift (`updatePlaybackState`), or `stop()` of a video with accrued
    /// progress — NOT on a bare `play` start. The Home-root observer (which fires
    /// without any navigation, e.g. a floating video finishing while the user
    /// sits on Home) keys on THIS so a bare start, which has no new resume state
    /// yet, can't trigger a premature rebuild that advances the watermark and
    /// then swallows the real progress. The value passed to the view model is
    /// still `watchActivityGeneration`; this only decides *when* that observer
    /// fires. (Navigation-return observers use `watchActivityGeneration` directly:
    /// by the time the user navigates back, progress has accrued.)
    private(set) var watchConclusionGeneration = 0

    /// True once the current video has already signalled its conclusion (a
    /// natural finish via `handleVideoEnded`). It prevents `stop()` — which often
    /// follows a finish when the user closes the floating window — from
    /// re-signalling the same already-finished video as a fresh partial-watch
    /// conclusion (a double bump that would cancel/restart the refresh the finish
    /// just scheduled). Reset whenever a new video becomes current.
    private var currentWatchConcluded = false

    /// Whether the video is currently playing.
    private(set) var isPlaying = false

    /// Current position in seconds.
    private(set) var progress: Double = 0

    /// Video length in seconds.
    private(set) var duration: Double = 0

    /// Whether an ad is currently showing on the watch page.
    private(set) var isShowingAd = false

    /// Playback volume (0...1).
    var volume: Double = 1.0 {
        didSet {
            guard oldValue != self.volume else { return }
            self.playbackController.setVolume(self.volume)
        }
    }

    /// Where the extracted video surface currently lives.
    enum SurfaceLocation: Equatable {
        case none
        case inline
        case floating
    }

    /// Current surface placement. KasetApp observes this to open/close the
    /// floating window.
    private(set) var surfaceLocation: SurfaceLocation = .none

    /// The videoId of the WatchView that currently owns the inline surface.
    var activeInlineVideoId: String?

    /// The user's rating of the current video (optimistic; YouTube doesn't
    /// expose the initial rating cheaply, so this tracks local actions).
    private(set) var currentRating: YouTubeRating = .none

    /// Set when the floating window asks to dock back into the app.
    /// KasetApp brings the app to the video source; YouTubeContentView
    /// opens/adopts the watch view and consumes the request.
    private(set) var popInRequest: YouTubeVideo?

    /// Up-next candidates for skip-forward (related videos from the watch page).
    private(set) var upNext: [YouTubeVideo] = []

    /// Videos played earlier this session, for skip-backward.
    private var history: [YouTubeVideo] = []

    /// Set when a skip changes the video while docked inline so
    /// YouTubeContentView can open the new video's watch view.
    private(set) var skipNavigationRequest: YouTubeVideo?

    /// Whether the current video was added to Watch Later this session.
    private(set) var isInWatchLater = false

    /// Whether the pop-out window is in fullscreen (set by its controller).
    var isWindowFullscreen = false

    /// Caption tracks available on the current watch page.
    private(set) var captionTracks: [YouTubeCaptionTrack] = []

    /// Language code of the active caption track (nil = captions off).
    private(set) var activeCaptionLanguageCode: String?

    /// Quality levels available on the current watch page.
    private(set) var qualityLevels: [String] = []

    /// The player's current quality level.
    private(set) var currentQuality: String?

    /// YouTube storyboard spec for the current video (drives the ambient
    /// backdrop's fine-grained live color). `nil` until fetched / unavailable.
    private(set) var storyboardSpec: String?

    /// The video id whose storyboard spec has been *resolved* — either
    /// successfully fetched, or confirmed absent after a full retry while real
    /// content (not a preroll ad) was playing. Acts as a positive+negative cache
    /// so a re-trigger for the same video is a no-op and storyboard-less videos
    /// don't re-fetch on every playback update.
    private var storyboardFetchVideoId: String?

    /// The video id whose storyboard fetch loop is currently running, to avoid
    /// spawning overlapping loops / repeated WebView evaluations for one video.
    private var storyboardFetchInFlightVideoId: String?

    /// The video whose playback options were last fetched.
    private var playbackOptionsVideoId: String?

    /// Client used by rating actions from the playback controls.
    /// Set once by KasetApp; optional so unit tests don't need it.
    @ObservationIgnored var youtubeClient: (any YouTubeClientProtocol)?

    // MARK: - Hooks

    /// Called right before video playback starts (PlaybackArbiter pauses music).
    var playbackWillStart: (() -> Void)?

    /// Called when the current video finishes (WatchView advances to related).
    var onVideoEnded: ((String?) -> Void)?

    // MARK: - Dependencies

    private let webKitManager: WebKitManager
    private let playbackController: any YouTubeWatchPlaybackControlling
    private let logger = DiagnosticsLogger.player

    /// Whether a playing video should pop out into the floating window when the
    /// inline watch view disappears (navigate-away). Read live so the user's
    /// setting takes effect mid-session; injected so tests stay deterministic
    /// without touching global `UserDefaults`.
    private let shouldPopOutOnNavigateAway: @MainActor () -> Bool

    init(
        webKitManager: WebKitManager = .shared,
        playbackController: (any YouTubeWatchPlaybackControlling)? = nil,
        shouldPopOutOnNavigateAway: @escaping @MainActor () -> Bool = { SettingsManager.shared.popOutVideoOnNavigateAway }
    ) {
        self.webKitManager = webKitManager
        self.playbackController = playbackController ?? YouTubeWatchWebView.shared
        self.shouldPopOutOnNavigateAway = shouldPopOutOnNavigateAway
    }

    // MARK: - Commands

    /// Starts playback of a video, docked inline.
    func play(video: YouTubeVideo) {
        self.logger.info("YouTubePlayer: play video")
        self.playbackWillStart?()

        if let current = self.currentVideo, current.videoId != video.videoId {
            self.rememberInHistory(current)
        }
        self.upNext = []
        self.currentVideo = video
        self.watchActivityGeneration += 1 // a new watch began
        self.currentWatchConcluded = false
        self.resetPerVideoState()
        self.surfaceLocation = .inline

        // Create the WebView on demand; containers reparent it on appear.
        self.playbackController.prepare(webKitManager: self.webKitManager, playerService: self)
        self.playbackController.loadVideo(videoId: video.videoId)
    }

    /// Toggles play/pause.
    func playPause() {
        if !self.isPlaying {
            self.playbackWillStart?()
        }
        self.playbackController.playPause()
    }

    /// Resumes playback.
    func resume() {
        self.playbackWillStart?()
        self.playbackController.play()
    }

    /// Pauses playback.
    func pause() {
        self.playbackController.pause()
    }

    /// Seeks to a position in seconds.
    func seek(to time: Double) {
        self.progress = time
        self.playbackController.seek(to: time)
    }

    /// Stops playback entirely and releases the surface.
    func stop() {
        self.logger.info("YouTubePlayer: stop")
        // Closing/stopping a video that accrued progress changes its resume
        // state in history, so signal the conclusion before clearing — this
        // covers closing the floating window (windowWillClose -> stop) and
        // navigating away with pop-out disabled (inlineSurfaceWillDisappear ->
        // stop) after a partial watch, neither of which emits a skip or finish
        // event. `signalWatchConclusion` de-dupes, so a close right after a
        // natural end (already signalled) does not re-signal the finished video.
        if self.currentVideo != nil, self.progress > 0 {
            if self.signalWatchConclusion() {
                self.watchActivityGeneration += 1
            }
        }
        self.currentVideo = nil
        self.isPlaying = false
        self.progress = 0
        self.duration = 0
        self.isShowingAd = false
        self.resetPerVideoState()
        self.surfaceLocation = .none
        self.activeInlineVideoId = nil
        self.popInRequest = nil
        self.upNext = []
        self.history = []
        self.skipNavigationRequest = nil
        self.pauseInPlaceOnDisappear = false
        self.playbackController.tearDown()
    }

    // MARK: - Surface Placement

    /// Moves the surface to the floating video window.
    func popOutToWindow() {
        guard self.currentVideo != nil else { return }
        self.logger.info("YouTubePlayer: pop out to floating window")
        self.surfaceLocation = .floating
    }

    /// Docks the surface back into the inline watch view.
    func dockInline() {
        guard self.currentVideo != nil else { return }
        self.logger.info("YouTubePlayer: dock inline")
        self.surfaceLocation = .inline
    }

    /// The floating window asked to dock the video back into the app.
    func requestPopIn() {
        guard self.surfaceLocation == .floating, let video = self.currentVideo else { return }
        self.popInRequest = video
    }

    /// Marks the pop-in request as handled.
    func consumePopInRequest() {
        self.popInRequest = nil
    }

    // MARK: - Skipping

    /// Supplies up-next candidates (the watch page's related list).
    func setUpNext(_ videos: [YouTubeVideo]) {
        let currentId = self.currentVideo?.videoId
        self.upNext = videos.filter { $0.videoId != currentId && !$0.isShort }
    }

    /// Skips to the next video (first up-next candidate; fetched lazily
    /// when none are known, e.g. when playing in the floating window).
    func skipForward() async {
        guard let current = self.currentVideo else { return }

        var target = self.upNext.first
        if target == nil, let client = self.youtubeClient {
            target = await (try? client.getWatchNext(videoId: current.videoId))?
                .related.first { !$0.isShort }
        }
        guard let next = target else { return }
        self.advance(to: next)
    }

    /// Skips back to the previously played video, or restarts the current
    /// one when there is no history.
    func skipBackward() {
        if let previous = self.history.popLast() {
            self.advance(to: previous, recordingHistory: false)
        } else {
            self.seek(to: 0)
        }
    }

    /// Marks the skip navigation request as handled.
    func consumeSkipNavigationRequest() {
        self.skipNavigationRequest = nil
    }

    private func advance(to video: YouTubeVideo, recordingHistory: Bool = true) {
        self.logger.info("YouTubePlayer: advancing to another video")
        if recordingHistory, let current = self.currentVideo {
            self.rememberInHistory(current)
        }
        self.upNext.removeAll { $0.videoId == video.videoId }

        self.playbackWillStart?()
        self.currentVideo = video
        // A skip concludes the prior watch (deduped) and begins a new one.
        self.signalWatchConclusion()
        self.watchActivityGeneration += 1
        self.currentWatchConcluded = false
        self.resetPerVideoState()
        self.playbackController.prepare(webKitManager: self.webKitManager, playerService: self)
        self.playbackController.loadVideo(videoId: video.videoId)

        // Keep the surface where it is; when docked inline the content view
        // opens the new video's watch view.
        if self.surfaceLocation == .inline {
            self.skipNavigationRequest = video
        }
    }

    private func rememberInHistory(_ video: YouTubeVideo) {
        self.history.append(video)
        if self.history.count > 50 {
            self.history.removeFirst()
        }
    }

    /// Clears state that is scoped to a single video.
    private func resetPerVideoState() {
        self.progress = 0
        self.duration = 0
        self.currentRating = .none
        self.isInWatchLater = false
        self.captionTracks = []
        self.activeCaptionLanguageCode = nil
        self.qualityLevels = []
        self.currentQuality = nil
        self.storyboardSpec = nil
        self.storyboardFetchVideoId = nil
        self.storyboardFetchInFlightVideoId = nil
        self.playbackOptionsVideoId = nil
    }

    // MARK: - Watch Later

    /// Adds/removes the current video from Watch Later (optimistic with rollback).
    func toggleWatchLater() async {
        guard let video = self.currentVideo, let client = self.youtubeClient else { return }
        let wasInWatchLater = self.isInWatchLater
        self.isInWatchLater = !wasInWatchLater
        do {
            if wasInWatchLater {
                try await client.removeFromWatchLater(videoId: video.videoId)
            } else {
                try await client.addToWatchLater(videoId: video.videoId)
            }
            HapticService.toggle()
        } catch {
            self.logger.error("Failed to edit Watch Later: \(error.localizedDescription)")
            self.isInWatchLater = wasInWatchLater
        }
    }

    // MARK: - Captions & Quality

    /// Loads the caption tracks and quality levels the watch page offers.
    /// Retries briefly — the captions module often isn't ready the moment
    /// playback starts — and reads the player's actual caption state
    /// (YouTube persists captions-on across sessions).
    func refreshPlaybackOptions() async {
        let videoId = self.currentVideo?.videoId
        for attempt in 0 ..< 3 {
            let tracks = await self.playbackController.availableCaptionTracks()
            guard self.currentVideo?.videoId == videoId else { return }

            self.captionTracks = tracks
            self.qualityLevels = await self.playbackController.availableQualityLevels()
            self.currentQuality = await self.playbackController.currentQualityLevel()
            self.activeCaptionLanguageCode = await self.playbackController.currentCaptionLanguageCode()

            if !tracks.isEmpty || attempt == 2 {
                return
            }
            try? await Task.sleep(for: .milliseconds(1500))
        }
    }

    /// Fetches the storyboard spec for the ambient backdrop, keyed to its video
    /// so a previous video's spec never leaks forward. Kept separate from
    /// `refreshPlaybackOptions` so this cosmetic-only data never delays caption
    /// or quality loading. Retries briefly since the player response, like the
    /// captions module, isn't ready the instant playback starts.
    func refreshStoryboardSpec() async {
        let videoId = self.currentVideo?.videoId
        // Already resolved this exact video (got a spec, or confirmed it has
        // none after a full retry) — nothing to do. The trigger only calls this
        // for real content, never during a preroll ad, so a resolved `nil` here
        // is a genuine "no storyboard" and is safe to cache as a negative result
        // instead of re-fetching on every 1 Hz playback update.
        if self.storyboardFetchVideoId == videoId {
            return
        }
        if self.storyboardFetchInFlightVideoId == videoId {
            return
        }
        self.storyboardFetchInFlightVideoId = videoId
        defer {
            if self.storyboardFetchInFlightVideoId == videoId {
                self.storyboardFetchInFlightVideoId = nil
            }
        }
        // Drop any spec from a previous video before awaiting the refetch.
        self.storyboardSpec = nil
        self.storyboardFetchVideoId = nil

        for attempt in 0 ..< 3 {
            let spec = await self.playbackController.storyboardSpec(expectedVideoId: videoId)
            guard self.currentVideo?.videoId == videoId else { return }
            if let spec {
                self.storyboardSpec = spec
                self.storyboardFetchVideoId = videoId
                return
            }
            if attempt == 2 {
                // Retries exhausted on real content: cache the negative result
                // so we don't loop forever on a storyboard-less video.
                self.storyboardFetchVideoId = videoId
                return
            }
            try? await Task.sleep(for: .milliseconds(1500))
        }
    }

    /// Selects a caption track (nil turns captions off).
    func selectCaptionTrack(languageCode: String?) {
        self.activeCaptionLanguageCode = languageCode
        self.playbackController.setCaptionTrack(languageCode: languageCode)
        HapticService.toggle()
    }

    /// Selects a playback quality level.
    func selectQuality(_ level: String) {
        self.currentQuality = level
        self.playbackController.setQualityLevel(level)
        HapticService.toggle()
    }

    // MARK: - AirPlay

    /// Shows the system AirPlay picker for the video element.
    func showAirPlayPicker() {
        self.playbackController.showAirPlayPicker()
    }

    // MARK: - Rating

    /// Toggles a like on the current video (optimistic with rollback).
    func toggleLike() async {
        await self.setRating(self.currentRating == .like ? .none : .like)
    }

    /// Toggles a dislike on the current video (optimistic with rollback).
    func toggleDislike() async {
        await self.setRating(self.currentRating == .dislike ? .none : .dislike)
    }

    private func setRating(_ newRating: YouTubeRating) async {
        guard let video = self.currentVideo, let client = self.youtubeClient else { return }
        let previous = self.currentRating
        self.currentRating = newRating
        do {
            try await client.rateVideo(videoId: video.videoId, rating: newRating)
            HapticService.toggle()
        } catch {
            self.logger.error("Failed to rate video: \(error.localizedDescription)")
            self.currentRating = previous
        }
    }

    /// Set by the source toggle right before switching away from the video
    /// source: the inline surface pauses in place (no pop-out window) and
    /// the restored watch view re-adopts it when the user comes back.
    private var pauseInPlaceOnDisappear = false

    /// Prepares the inline surface for a switch to the music source:
    /// pause in place, keep everything loaded for restore.
    func prepareForSourceSwitch() {
        guard self.surfaceLocation == .inline, self.currentVideo != nil else { return }
        if self.isPlaying {
            self.pause()
        }
        self.pauseInPlaceOnDisappear = true
    }

    /// A WatchView for `videoId` is disappearing. If it owns the inline
    /// surface, hand off: keep playing in the floating window, stop if
    /// paused — or, during a source switch, stay paused in place.
    func inlineSurfaceWillDisappear(videoId: String) {
        guard self.activeInlineVideoId == videoId else { return }
        self.activeInlineVideoId = nil

        guard self.currentVideo?.videoId == videoId, self.surfaceLocation == .inline else {
            self.pauseInPlaceOnDisappear = false
            return
        }

        if self.pauseInPlaceOnDisappear {
            self.pauseInPlaceOnDisappear = false
            // Surface stays .inline and paused; returning to the video
            // source re-adopts it on the same watch view.
            return
        }

        if self.isPlaying, self.shouldPopOutOnNavigateAway() {
            self.popOutToWindow()
        } else {
            // Playing with pop-out disabled, or paused: stop instead of
            // leaving a detached surface.
            self.stop()
        }
    }

    // MARK: - Bridge Callbacks

    /// A `STATE_UPDATE` payload from the watch page observer script.
    struct PlaybackUpdate {
        let isPlaying: Bool
        let progress: Double
        let duration: Double
        var videoId: String?
        var title: String?
        var isAd = false
    }

    /// Applies a `STATE_UPDATE` from the watch page observer script.
    func updatePlaybackState(_ update: PlaybackUpdate) {
        // YouTube can start the next video on its own (SPA navigation);
        // make sure music yields whenever video audio actually starts.
        if update.isPlaying, !self.isPlaying {
            self.playbackWillStart?()
        }

        self.isPlaying = update.isPlaying
        self.progress = update.progress
        self.duration = update.duration
        self.isShowingAd = update.isAd

        // A concluded video that is playing again (replayed via the player bar or
        // a seek back after it finished) begins a fresh watch — clear the
        // conclusion flag so its later stop/finish signals the new partial
        // rewatch instead of being deduped. Only when it's the same current video
        // still playing real content (drift to a different id is handled below
        // and starts its own unconcluded watch).
        if self.currentWatchConcluded,
           update.isPlaying,
           !update.isAd,
           let videoId = update.videoId,
           videoId == self.currentVideo?.videoId
        {
            self.currentWatchConcluded = false
        }

        // Fetch captions/quality options once per video, after playback starts
        // (the player APIs aren't ready before that).
        if update.isPlaying,
           let videoId = self.currentVideo?.videoId,
           self.playbackOptionsVideoId != videoId
        {
            self.playbackOptionsVideoId = videoId
            Task {
                await self.refreshPlaybackOptions()
            }
        }

        // Storyboard color drives the ambient backdrop, so only fetch it when
        // the feature is on and real content (not a preroll ad) is playing.
        // Not gated on the one-shot playback-options branch above, so it also
        // fires when the user enables ambient mid-playback or when content
        // starts after an ad. `refreshStoryboardSpec` is self-guarding, so
        // calling it on each qualifying update is cheap.
        if update.isPlaying,
           !update.isAd,
           self.currentVideo != nil,
           SettingsManager.shared.ambientBackdropEnabled
        {
            Task {
                await self.refreshStoryboardSpec()
            }
        }

        // Track SPA drift: if the page moved to a different video, follow it
        // so the controls stay truthful.
        if let videoId = update.videoId, let current = self.currentVideo,
           videoId != current.videoId
        {
            self.logger.info("YouTubePlayer: page drifted to a different video, following")
            self.resetPerVideoState()
            self.currentVideo = YouTubeVideo(
                videoId: videoId,
                title: update.title ?? current.title,
                channelName: current.channelName,
                channelId: current.channelId
            )
            // The page autoplayed/navigated to a new video (e.g. in the floating
            // window) — the prior video concluded and a new watch began. Signal
            // the conclusion (unless it already finished, to avoid double-bumping
            // a natural end that auto-advances), then mark the new video as a
            // fresh, unconcluded watch.
            self.signalWatchConclusion()
            self.watchActivityGeneration += 1
            self.currentWatchConcluded = false
            YouTubeWatchWebView.shared.currentVideoId = videoId
        }
    }

    /// Handles natural video completion.
    func handleVideoEnded(videoId: String?) {
        self.logger.info("YouTubePlayer: video ended")
        // Ignore an ended event that is not for the CURRENT content watch:
        //   - a late `VIDEO_ENDED` for the previous video arriving after a skip
        //     or SPA drift already made another video current (stale id), and
        //   - an ad's video element firing `VIDEO_ENDED` while an ad is showing.
        // Either would wrongly mark the active watch concluded and dedupe its
        // real conclusion. When the bridge supplies no id we fall back to the
        // current video (the common floating-window finish).
        let isStaleId = videoId != nil && videoId != self.currentVideo?.videoId
        guard !isStaleId, !self.isShowingAd else {
            self.logger.debug("YouTubePlayer: ignoring ended event (stale id or ad)")
            return
        }
        self.isPlaying = false
        // A finish changes watch history (the video crosses into "finished"), so
        // signal it — this lets Home drop a just-finished video from Continue
        // Watching even when the video ended in the floating window while the
        // user was already sitting on Home (no navigation fires).
        if self.signalWatchConclusion() {
            self.watchActivityGeneration += 1
        }
        self.onVideoEnded?(videoId)
    }

    /// Marks the CURRENT watch as concluded with resume state to reflect and
    /// advances `watchConclusionGeneration` — de-duplicated, so a watch is only
    /// signalled once no matter how many conclusion paths fire for it (a natural
    /// finish followed by an auto-advance drift or a window close would otherwise
    /// double-bump and make Home cancel/restart the refresh the first conclusion
    /// scheduled). Does NOT touch `watchActivityGeneration`: callers bump that
    /// once per watch-state transition (a skip/drift bumps it for the new watch;
    /// a finish/stop bumps it here). Callers that begin a NEW watch (`advance`,
    /// drift) clear `currentWatchConcluded` afterward so the next watch can
    /// signal.
    @discardableResult
    private func signalWatchConclusion() -> Bool {
        guard !self.currentWatchConcluded else { return false }
        self.watchConclusionGeneration += 1
        self.currentWatchConcluded = true
        return true
    }
}
