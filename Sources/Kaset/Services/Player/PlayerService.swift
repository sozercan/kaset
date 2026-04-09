import Foundation
import Observation
import os

// MARK: - PlayerService

/// Controls music playback via a hidden WKWebView.
@MainActor
@Observable
final class PlayerService: NSObject, PlayerServiceProtocol {
    /// Shared instance for AppleScript access.
    ///
    /// **Safety Invariant:** This property is set exactly once during app initialization
    /// in `KasetApp.init()` before any AppleScript commands can be received, and is never
    /// modified afterward. The property is `@MainActor`-isolated along with the entire class,
    /// ensuring thread-safe access from AppleScript commands (which run on the main thread).
    ///
    /// AppleScript commands should handle the `nil` case gracefully by returning an error
    /// to the caller, as there's a brief window during app launch before initialization completes.
    static var shared: PlayerService?
    /// Current playback state.
    enum PlaybackState: Equatable {
        case idle
        case loading
        case playing
        case paused
        case buffering
        case ended
        case error(String)

        var isPlaying: Bool {
            self == .playing
        }
    }

    /// Repeat mode for playback.
    enum RepeatMode {
        case off
        case all
        case one
    }

    // MARK: - Observable State

    /// Current playback state.
    var state: PlaybackState = .idle

    /// Currently playing track.
    var currentTrack: Song?

    /// Whether playback is active.
    var isPlaying: Bool {
        self.state.isPlaying
    }

    /// Current playback position in seconds.
    var progress: TimeInterval = 0

    /// High-resolution playback time in milliseconds, updated at ~10Hz when synced lyrics are active.
    var currentTimeMs: Int = 0

    /// Total duration of current track in seconds.
    var duration: TimeInterval = 0

    /// Current volume (0.0 - 1.0).
    private(set) var volume: Double = 1.0

    /// Volume before muting, for unmute restoration.
    private var volumeBeforeMute: Double = 1.0

    /// Whether audio is currently muted.
    var isMuted: Bool {
        self.volume == 0
    }

    /// Whether shuffle mode is enabled.
    private(set) var shuffleEnabled: Bool = false

    /// Current repeat mode.
    private(set) var repeatMode: RepeatMode = .off

    /// Playback queue.
    var queue: [Song] = []

    /// Index of current track in queue.
    var currentIndex: Int = 0

    /// Whether the mini player should be shown (user needs to interact to start playback).
    var showMiniPlayer: Bool = false

    /// The video ID that needs to be played in the mini player.
    var pendingPlayVideoId: String?

    /// Whether the user has successfully interacted at least once this session.
    /// After first successful playback, we can auto-play without showing the popup.
    private(set) var hasUserInteractedThisSession: Bool = false

    /// Saved seek position to apply once a restored session finishes loading.
    var pendingRestoredSeek: TimeInterval?

    /// Whether a restored session is waiting for an explicit user-triggered load.
    var isPendingRestoredLoadDeferred: Bool = false

    /// Whether launch-time session restoration is still reconciling with the player observer.
    var isRestoringPlaybackSession: Bool = false

    /// Whether a restored load should automatically resume after seeking to the saved position.
    var shouldAutoResumeAfterRestoredLoad: Bool = false

    /// Like status of the current track.
    var currentTrackLikeStatus: LikeStatus = .indifferent

    /// Whether the current track is in the user's library.
    var currentTrackInLibrary: Bool = false

    /// Feedback tokens for the current track (used for library add/remove).
    var currentTrackFeedbackTokens: FeedbackTokens?

    /// Whether the lyrics panel is visible.
    var showLyrics: Bool = false {
        didSet {
            // Mutual exclusivity: opening lyrics closes queue
            if self.showLyrics, self.showQueue {
                self.showQueue = false
            }
        }
    }

    /// Display mode for the queue panel (popup vs side panel).
    var queueDisplayMode: QueueDisplayMode = .popup

    /// Whether the queue panel is visible.
    var showQueue: Bool = false {
        didSet {
            // Mutual exclusivity: opening queue closes lyrics
            if self.showQueue, self.showLyrics {
                self.showLyrics = false
            }
        }
    }

    /// Whether the current track has video available.
    var currentTrackHasVideo: Bool = false

    /// Whether video mode is active (user has opened video window).
    /// Note: We don't auto-close based on currentTrackHasVideo here because
    /// the detection can be unreliable when video mode CSS is active.
    var showVideo: Bool = false

    /// Whether AirPlay is currently connected (playing to a wireless target).
    private(set) var isAirPlayConnected: Bool = false

    /// Whether the user has requested AirPlay this session (for persistence across track changes).
    private(set) var airPlayWasRequested: Bool = false

    // MARK: - Internal Properties (for extensions)

    let logger = DiagnosticsLogger.player
    var ytMusicClient: (any YTMusicClientProtocol)?

    /// Continuation token for loading more songs in infinite mix/radio.
    var mixContinuationToken: String?

    /// Whether we're currently fetching more mix songs.
    var isFetchingMoreMixSongs: Bool = false

    /// UserDefaults key for persisting queue display mode.
    static let queueDisplayModeKey = "kaset.queue.displayMode"

    /// Undo/redo history for queue (up to 10 states). In-memory only.
    private var queueUndoHistory: [([Song], Int)] = []
    private var queueRedoHistory: [([Song], Int)] = []
    private static let queueUndoMaxCount = 10

    /// Queue index before each `next()`; `previous()` pops so Back returns to the track you skipped from (shuffle- and seek-safe).
    private var forwardSkipIndexStack: [Int] = []

    /// UserDefaults key for persisting volume.
    static let volumeKey = "playerVolume"
    /// UserDefaults key for persisting volume before mute.
    static let volumeBeforeMuteKey = "playerVolumeBeforeMute"
    /// UserDefaults key for persisting shuffle state.
    static let shuffleEnabledKey = "playerShuffleEnabled"
    /// UserDefaults key for persisting repeat mode.
    static let repeatModeKey = "playerRepeatMode"

    /// Task handle for the background queue metadata enrichment service.
    var enrichmentTask: Task<Void, Never>?

    // MARK: - Initialization

    override init() {
        super.init()
        // Restore saved volume from UserDefaults
        if UserDefaults.standard.object(forKey: Self.volumeKey) != nil {
            let savedVolume = UserDefaults.standard.double(forKey: Self.volumeKey)
            self.volume = max(0, min(1, savedVolume))
            self.logger.info("Restored saved volume: \(self.volume)")
        }
        // Restore volumeBeforeMute for proper unmute behavior
        if UserDefaults.standard.object(forKey: Self.volumeBeforeMuteKey) != nil {
            let savedVolumeBeforeMute = UserDefaults.standard.double(forKey: Self.volumeBeforeMuteKey)
            self.volumeBeforeMute = savedVolumeBeforeMute > 0 ? savedVolumeBeforeMute : 1.0
            self.logger.info("Restored volumeBeforeMute: \(self.volumeBeforeMute)")
        } else {
            self.volumeBeforeMute = self.volume > 0 ? self.volume : 1.0
        }

        // Restore shuffle and repeat settings if enabled in settings
        if SettingsManager.shared.rememberPlaybackSettings {
            if UserDefaults.standard.object(forKey: Self.shuffleEnabledKey) != nil {
                self.shuffleEnabled = UserDefaults.standard.bool(forKey: Self.shuffleEnabledKey)
                self.logger.info("Restored shuffle state: \(self.shuffleEnabled)")
            }

            if let savedRepeatMode = UserDefaults.standard.string(forKey: Self.repeatModeKey) {
                switch savedRepeatMode {
                case "all":
                    self.repeatMode = .all
                case "one":
                    self.repeatMode = .one
                case "off":
                    self.repeatMode = .off
                default:
                    self.logger.warning("Unexpected repeat mode value in UserDefaults: \(savedRepeatMode), defaulting to off")
                    self.repeatMode = .off
                }
                self.logger.info("Restored repeat mode: \(String(describing: self.repeatMode))")
            }
        }

        // Restore queue display mode
        if let savedMode = UserDefaults.standard.string(forKey: Self.queueDisplayModeKey),
           let mode = QueueDisplayMode(rawValue: savedMode)
        {
            self.queueDisplayMode = mode
            self.logger.info("Restored queue display mode: \(mode.displayName)")
        }

        // Load mock state for UI tests
        self.loadMockStateIfNeeded()

        // Start queue metadata enrichment service
        self.startQueueEnrichmentService()
    }

    /// Returns true if the given song is the current track.
    func isCurrentTrack(_ song: Song) -> Bool {
        self.currentTrack?.videoId == song.videoId
    }

    /// Whether the persistent player should navigate to the pending video immediately.
    var shouldAutoloadPendingVideo: Bool {
        !self.isPendingRestoredLoadDeferred
    }

    /// Toggles between popup and side panel queue display modes.
    func toggleQueueDisplayMode() {
        if self.queueDisplayMode == .popup {
            self.queueDisplayMode = .sidepanel
        } else {
            self.queueDisplayMode = .popup
        }
        UserDefaults.standard.set(self.queueDisplayMode.rawValue, forKey: Self.queueDisplayModeKey)
        self.logger.info("Queue display mode: \(self.queueDisplayMode.displayName)")
    }

    // MARK: - Queue Undo / Redo

    /// Whether queue undo is available.
    var canUndoQueue: Bool {
        !self.queueUndoHistory.isEmpty
    }

    /// Whether queue redo is available.
    var canRedoQueue: Bool {
        !self.queueRedoHistory.isEmpty
    }

    /// Records current queue state for undo (call before mutating queue). Clears redo. Keeps up to 3 states.
    func recordQueueStateForUndo() {
        let state = (self.queue, self.currentIndex)
        self.queueUndoHistory.append(state)
        if self.queueUndoHistory.count > Self.queueUndoMaxCount {
            self.queueUndoHistory.removeFirst()
        }
        self.queueRedoHistory.removeAll()
        self.logger.debug("Recorded queue state for undo, undo count: \(self.queueUndoHistory.count)")
    }

    /// Restores the previous queue state. Does nothing if undo history is empty.
    func undoQueue() {
        guard let state = self.queueUndoHistory.popLast() else { return }
        let (previousQueue, previousIndex) = state
        self.queueRedoHistory.append((self.queue, self.currentIndex))
        self.queue = previousQueue
        self.currentIndex = min(previousIndex, max(0, previousQueue.count - 1))
        self.saveQueueForPersistence()
        self.logger.info("Undid queue to \(previousQueue.count) songs at index \(self.currentIndex)")
        self.clearForwardSkipNavigationStack()
    }

    /// Restores the next queue state after an undo. Does nothing if redo history is empty.
    func redoQueue() {
        guard let state = self.queueRedoHistory.popLast() else { return }
        let (nextQueue, nextIndex) = state
        self.queueUndoHistory.append((self.queue, self.currentIndex))
        self.queue = nextQueue
        self.currentIndex = min(nextIndex, max(0, nextQueue.count - 1))
        self.saveQueueForPersistence()
        self.logger.info("Redid queue to \(nextQueue.count) songs at index \(self.currentIndex)")
        self.clearForwardSkipNavigationStack()
    }

    /// Clears forward-skip undo when the queue is replaced or reordered so indices are not stale.
    func clearForwardSkipNavigationStack() {
        self.forwardSkipIndexStack.removeAll()
    }

    /// Records the current index before `next()` moves to `newIndex` (no-op if unchanged).
    private func pushForwardSkipStackIfLeavingIndex(for newIndex: Int) {
        let from = self.currentIndex
        guard from != newIndex else { return }
        self.forwardSkipIndexStack.append(from)
    }

    /// Loads mock player state from environment variables for UI testing.
    private func loadMockStateIfNeeded() {
        guard UITestConfig.isUITestMode else { return }

        // Load mock current track
        if let jsonString = UITestConfig.environmentValue(for: UITestConfig.mockCurrentTrackKey),
           let data = jsonString.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = dict["id"] as? String,
           let title = dict["title"] as? String,
           let videoId = dict["videoId"] as? String
        {
            let artist = dict["artist"] as? String ?? "Unknown Artist"
            let duration: TimeInterval? = (dict["duration"] as? Int).map { TimeInterval($0) }
            self.currentTrack = Song(
                id: id,
                title: title,
                artists: [Artist(id: "mock-artist", name: artist)],
                album: nil,
                duration: duration,
                thumbnailURL: nil,
                videoId: videoId
            )
            self.logger.debug("Loaded mock current track: \(title)")
        }

        // Load mock playing state
        if let isPlayingString = UITestConfig.environmentValue(for: UITestConfig.mockIsPlayingKey) {
            let isPlaying = isPlayingString == "true"
            self.state = isPlaying ? .playing : .paused
            self.logger.debug("Loaded mock playing state: \(isPlaying)")
        }

        // Load mock video availability
        if let hasVideoString = UITestConfig.environmentValue(for: UITestConfig.mockHasVideoKey) {
            let hasVideo = hasVideoString == "true"
            self.currentTrackHasVideo = hasVideo
            self.logger.debug("Loaded mock video availability: \(hasVideo)")
        }
    }

    /// Sets the YTMusicClient for API calls (dependency injection).
    func setYTMusicClient(_ client: any YTMusicClientProtocol) {
        self.ytMusicClient = client
    }

    // MARK: - Public Methods

    /// Plays a track by video ID.
    func play(videoId: String) async {
        self.logger.debug("play() called with videoId: \(videoId)")
        self.logger.info("Playing video: \(videoId)")
        self.clearRestoredPlaybackSessionState()
        self.state = .loading
        self.songNearingEnd = false
        self.shouldSuppressAutoplayAfterQueueEnd = false

        // Create a minimal Song object for now
        self.currentTrack = Song(
            id: videoId,
            title: "Loading...",
            artists: [],
            album: nil,
            duration: nil,
            thumbnailURL: nil,
            videoId: videoId
        )

        self.pendingPlayVideoId = videoId

        // If user has already interacted this session, auto-play without popup
        if self.hasUserInteractedThisSession {
            self.logger.info("User has interacted before, auto-playing without popup")
            self.showMiniPlayer = false
            // Load the video directly - WebView session should allow autoplay
            SingletonPlayerWebView.shared.loadVideo(videoId: videoId)
        } else {
            // First time: show the mini player for user interaction
            self.showMiniPlayer = true
            self.logger.info("Showing mini player for first-time user interaction")
        }

        // Fetch full song metadata in the background to get feedbackTokens
        await self.fetchSongMetadata(videoId: videoId)
    }

    /// Plays a song.
    func play(song: Song) async {
        await self.play(song: song, webLoadStrategy: .standard)
    }

    /// Plays a song.
    /// - Parameter webLoadStrategy: Controls duplicate-`videoId` behavior in ``SingletonPlayerWebView/loadVideo(videoId:strategy:)``
    ///   (repeat-one prefers in-place restart; queue drift correction may force a full page load).
    func play(song: Song, webLoadStrategy: SingletonPlayerWebView.VideoLoadStrategy) async {
        self.logger.info("Playing song: \(song.title)")
        self.logger.debug("Web load strategy: \(String(describing: webLoadStrategy))")
        self.clearRestoredPlaybackSessionState()
        // Brief `.loading` until the observer reports playback; in-place restarts may flash loading briefly.
        self.state = .loading
        self.songNearingEnd = false
        self.shouldSuppressAutoplayAfterQueueEnd = false
        self.currentTrack = song

        // Mark that we initiated this playback (to detect and correct YouTube's autoplay override)
        self.isKasetInitiatedPlayback = true

        // Use existing feedbackTokens if the song already has them
        if let tokens = song.feedbackTokens {
            self.currentTrackFeedbackTokens = tokens
            self.currentTrackInLibrary = song.isInLibrary ?? false
            if let likeStatus = song.likeStatus {
                self.currentTrackLikeStatus = likeStatus
            }
        }

        // SongLikeStatusManager cache is the most up-to-date source for like status;
        // use it to correct stale/missing song.likeStatus immediately.
        if let cachedStatus = SongLikeStatusManager.shared.status(for: song.videoId) {
            self.currentTrackLikeStatus = cachedStatus
        }

        self.pendingPlayVideoId = song.videoId

        // If user has already interacted this session, auto-play without popup
        if self.hasUserInteractedThisSession {
            self.logger.info("User has interacted before, auto-playing without popup")
            self.showMiniPlayer = false
            SingletonPlayerWebView.shared.loadVideo(videoId: song.videoId, strategy: webLoadStrategy)
        } else {
            // First time: show the mini player for user interaction
            self.showMiniPlayer = true
            self.logger.info("Showing mini player for first-time user interaction")
        }

        // Fetch full song metadata if we don't have feedbackTokens
        if song.feedbackTokens == nil {
            await self.fetchSongMetadata(videoId: song.videoId)
        }
    }

    /// Called when the mini player confirms playback has started.
    /// This is the only place that should open the session autoplay gate.
    func confirmPlaybackStarted() {
        self.showMiniPlayer = false
        self.state = .playing
        self.hasUserInteractedThisSession = true
        self.logger.info("Playback confirmed started, user interaction recorded")
    }

    /// Called when the mini player is dismissed.
    func miniPlayerDismissed() {
        self.showMiniPlayer = false
        if self.state == .loading {
            self.state = .idle
        }
    }

    func markPlaybackEnded() {
        self.state = .ended
    }

    /// Flag to track when a song is nearing its end.
    var songNearingEnd: Bool = false

    /// Flag to track when we initiated a track change (to correct YouTube's autoplay interference).
    /// This is set when we call play() and cleared after the track loads.
    var isKasetInitiatedPlayback: Bool = false

    /// Flag to suppress YouTube autoplay after the native queue has finished.
    var shouldSuppressAutoplayAfterQueueEnd: Bool = false

    /// Grace period instant - don't auto-close video window shortly after opening (uses monotonic clock)
    private var videoWindowOpenedAt: ContinuousClock.Instant?

    /// Debounces repeat-one recovery `play()` when YouTube sends bursty metadata (safety net in `PlayerService+WebQueueSync`).
    /// Internal so the WebQueueSync extension can throttle; not part of the public API.
    var lastRepeatOneRecoveryInstant: ContinuousClock.Instant?

    /// Updates whether the current track has video available.
    /// Note: This only affects the UI (enabling/disabling the video button).
    /// It does NOT auto-close an open video window, since hasVideo detection
    /// can be unreliable when the video element has been extracted by video mode CSS.
    func updateVideoAvailability(hasVideo: Bool) {
        let previousValue = self.currentTrackHasVideo
        self.currentTrackHasVideo = hasVideo

        // Don't auto-close the video window based on hasVideo detection.
        // The detection is unreliable when video mode is active because:
        // 1. The video element has been extracted from its original DOM location
        // 2. The Song/Video toggle buttons may be hidden by our CSS
        // 3. Resize or other layout changes can temporarily break detection
        //
        // Instead, we rely on trackChanged detection in the Coordinator to close
        // the video window when a new track starts.

        if previousValue != hasVideo {
            self.logger.debug("Video availability updated: \(hasVideo)")
        }
    }

    /// Called when video window opens to start grace period
    func videoWindowDidOpen() {
        self.videoWindowOpenedAt = ContinuousClock.now
        self.logger.debug("videoWindowDidOpen: grace period started")
    }

    /// Called when video window closes to clear grace period
    func videoWindowDidClose() {
        self.videoWindowOpenedAt = nil
        self.logger.debug("videoWindowDidClose: grace period cleared")
    }

    /// Returns true if video window was recently opened (within grace period)
    /// This is used to ignore spurious trackChanged events during video mode setup
    var isVideoGracePeriodActive: Bool {
        guard let openedAt = self.videoWindowOpenedAt else { return false }
        // 3 second grace period to allow video mode setup to complete
        return ContinuousClock.now - openedAt < .seconds(3)
    }

    /// Toggles play/pause.
    func playPause() async {
        self.logger.debug("Toggle play/pause")

        if self.isPendingRestoredLoadDeferred || self.pendingPlayVideoId != nil && self.shouldLoadPendingVideoBeforePlayback {
            await self.resume()
            return
        }

        self.clearRestoredPlaybackSessionState()

        // Use singleton WebView if we have a pending video
        if self.pendingPlayVideoId != nil {
            SingletonPlayerWebView.shared.playPause()
        } else if self.isPlaying {
            await self.pause()
        } else {
            await self.resume()
        }
    }

    /// Pauses playback.
    func pause() async {
        self.logger.debug("Pausing playback")

        if self.isPendingRestoredLoadDeferred {
            self.state = .paused
            return
        }

        self.clearRestoredPlaybackSessionState()
        if self.pendingPlayVideoId != nil {
            SingletonPlayerWebView.shared.pause()
        } else {
            await self.evaluatePlayerCommand("pause")
        }
    }

    /// Resumes playback.
    func resume() async {
        self.logger.debug("Resuming playback")

        guard let pendingPlayVideoId = self.pendingPlayVideoId else {
            self.clearRestoredPlaybackSessionState()
            await self.evaluatePlayerCommand("play")
            return
        }

        let shouldLoadPendingVideo = self.shouldLoadPendingVideoBeforePlayback
        if self.isPendingRestoredLoadDeferred {
            self.beginRestoredPlaybackLoad(autoResumeAfterSeek: self.hasUserInteractedThisSession)
        } else {
            self.clearRestoredPlaybackSessionState()
        }

        if shouldLoadPendingVideo {
            if self.hasUserInteractedThisSession {
                self.showMiniPlayer = false
                self.state = .loading
                SingletonPlayerWebView.shared.loadVideo(videoId: pendingPlayVideoId)
            } else {
                self.showMiniPlayer = true
                self.logger.info("Showing mini player so the user can resume playback")
            }
            return
        }

        if self.pendingPlayVideoId != nil {
            SingletonPlayerWebView.shared.play()
        } else {
            await self.evaluatePlayerCommand("play")
        }
    }

    /// Skips to next track.
    func next() async {
        self.logger.debug("Skipping to next track")
        self.clearRestoredPlaybackSessionState()

        // Prioritize local queue if we have one
        if !self.queue.isEmpty {
            // Repeat-one for natural **track end** is handled in `handleTrackEnded` (replay). The Next button advances the queue.

            // Handle shuffle mode - pick random track
            if self.shuffleEnabled {
                let randomIndex = Int.random(in: 0 ..< self.queue.count)
                self.pushForwardSkipStackIfLeavingIndex(for: randomIndex)
                self.currentIndex = randomIndex
                if let nextSong = queue[safe: currentIndex] {
                    await self.play(song: nextSong)
                }
                await self.fetchMoreMixSongsIfNeeded()
                self.saveQueueForPersistence()
                return
            }

            // Normal next behavior
            if self.currentIndex < self.queue.count - 1 {
                self.pushForwardSkipStackIfLeavingIndex(for: self.currentIndex + 1)
                self.currentIndex += 1
                if let nextSong = queue[safe: currentIndex] {
                    await self.play(song: nextSong)
                }
                // Check if we should fetch more songs
                await self.fetchMoreMixSongsIfNeeded()
                self.saveQueueForPersistence()
            } else if self.repeatMode == .all {
                // Loop back to start if repeat all is enabled
                self.pushForwardSkipStackIfLeavingIndex(for: 0)
                self.currentIndex = 0
                if let firstSong = queue.first {
                    await self.play(song: firstSong)
                }
                self.saveQueueForPersistence()
            } else if self.mixContinuationToken != nil {
                // At end of queue but have continuation - fetch more and continue
                let previousCount = self.queue.count
                await self.fetchMoreMixSongsIfNeeded()
                // Only advance if new songs were actually added
                if self.queue.count > previousCount {
                    self.pushForwardSkipStackIfLeavingIndex(for: self.currentIndex + 1)
                    self.currentIndex += 1
                    if let nextSong = queue[safe: currentIndex] {
                        await self.play(song: nextSong)
                    }
                    self.saveQueueForPersistence()
                }
            }
            // At end of queue with repeat off and no continuation, don't do anything
            return
        }

        // Fall back to YouTube's next if no local queue
        if self.pendingPlayVideoId != nil {
            SingletonPlayerWebView.shared.next()
        }
    }

    /// Goes to previous track.
    func previous() async {
        self.logger.debug("Going to previous track")
        self.clearRestoredPlaybackSessionState()

        // Prioritize local queue if we have one
        if !self.queue.isEmpty {
            // Standard behavior: past the first few seconds, Previous always goes to the start of the *current* track first.
            // Only when already near the start (progress ≤ 3s) do we go to the prior queue item or undo a `next()` skip.
            if self.progress > 3 {
                // Must use `seek(to:)` so `self.progress` updates immediately; raw WebView seek leaves stale progress
                // and every subsequent Previous keeps hitting this branch (never reaches prior track).
                await self.seek(to: 0)
                return
            }

            if let priorIndex = self.forwardSkipIndexStack.popLast(), self.queue.indices.contains(priorIndex) {
                self.currentIndex = priorIndex
                if let prevSong = self.queue[safe: priorIndex] {
                    await self.play(song: prevSong)
                }
                self.saveQueueForPersistence()
                return
            }

            if self.currentIndex > 0 {
                self.currentIndex -= 1
                if let prevSong = queue[safe: currentIndex] {
                    await self.play(song: prevSong)
                }
                self.saveQueueForPersistence()
            } else {
                // At start of queue, just restart current track
                await self.seek(to: 0)
            }
            return
        }

        // Fall back to YouTube's previous if no local queue
        if self.progress > 3 {
            if self.pendingPlayVideoId != nil {
                await self.seek(to: 0)
            } else {
                await self.seek(to: 0)
            }
        } else {
            SingletonPlayerWebView.shared.previous()
        }
    }

    /// Seeks to a specific time.
    func seek(to time: TimeInterval) async {
        let clampedTime = self.duration > 0 ? min(max(time, 0), self.duration) : max(time, 0)
        self.logger.debug("Seeking to \(clampedTime)")

        if self.isPendingRestoredLoadDeferred {
            self.progress = clampedTime
            self.pendingRestoredSeek = clampedTime
            return
        }

        self.clearRestoredPlaybackSessionState()
        if self.pendingPlayVideoId != nil {
            SingletonPlayerWebView.shared.seek(to: clampedTime)
            self.progress = clampedTime
        } else {
            await self.evaluatePlayerCommand("seekTo(\(clampedTime), true)")
        }
    }

    /// Sets the volume.
    func setVolume(_ value: Double) async {
        let clampedValue = max(0, min(1, value))
        self.volume = clampedValue

        // Persist volume to UserDefaults (including mute state of 0)
        UserDefaults.standard.set(clampedValue, forKey: Self.volumeKey)

        if self.pendingPlayVideoId != nil {
            SingletonPlayerWebView.shared.setVolume(clampedValue)
        } else {
            await self.evaluatePlayerCommand("setVolume(\(Int(clampedValue * 100)))")
        }
    }

    /// Toggles mute state. Remembers previous volume for unmuting.
    func toggleMute() async {
        if self.isMuted {
            // Unmute - restore previous volume
            let restoredVolume = self.volumeBeforeMute > 0 ? self.volumeBeforeMute : 1.0
            await self.setVolume(restoredVolume)
            self.logger.info("Unmuted, volume restored to \(restoredVolume)")
        } else {
            // Mute - save current volume and set to 0
            self.volumeBeforeMute = self.volume
            // Persist volumeBeforeMute so we can restore after app restart
            UserDefaults.standard.set(self.volumeBeforeMute, forKey: Self.volumeBeforeMuteKey)
            await self.setVolume(0)
            self.logger.info("Muted")
        }
    }

    /// Toggles shuffle mode.
    func toggleShuffle() {
        self.shuffleEnabled.toggle()
        // Persist shuffle state to UserDefaults if setting is enabled
        if SettingsManager.shared.rememberPlaybackSettings {
            UserDefaults.standard.set(self.shuffleEnabled, forKey: Self.shuffleEnabledKey)
        }
        let status = self.shuffleEnabled ? "enabled" : "disabled"
        self.logger.info("Shuffle mode: \(status)")
    }

    /// Cycles through repeat modes: off -> all -> one -> off.
    func cycleRepeatMode() {
        switch self.repeatMode {
        case .off:
            self.repeatMode = .all
        case .all:
            self.repeatMode = .one
        case .one:
            self.repeatMode = .off
        }
        // Persist repeat mode to UserDefaults if setting is enabled
        if SettingsManager.shared.rememberPlaybackSettings {
            let modeString = switch self.repeatMode {
            case .off:
                "off"
            case .all:
                "all"
            case .one:
                "one"
            }
            UserDefaults.standard.set(modeString, forKey: Self.repeatModeKey)
        }
        let mode = self.repeatMode
        self.logger.info("Repeat mode: \(String(describing: mode))")
    }

    /// Stops playback and clears state.
    func stop() async {
        self.logger.debug("Stopping playback")
        self.clearRestoredPlaybackSessionState()
        await self.evaluatePlayerCommand("pauseVideo()")
        self.state = .idle
        self.songNearingEnd = false
        self.isKasetInitiatedPlayback = false
        self.shouldSuppressAutoplayAfterQueueEnd = false
        self.currentTrack = nil
        self.progress = 0
        self.duration = 0
    }

    /// Show the AirPlay picker for selecting audio output devices.
    func showAirPlayPicker() {
        self.airPlayWasRequested = true
        SingletonPlayerWebView.shared.showAirPlayPicker()
    }

    /// Updates the AirPlay connection status from the WebView.
    func updateAirPlayStatus(isConnected: Bool, wasRequested: Bool = false) {
        self.isAirPlayConnected = isConnected
        if wasRequested {
            self.airPlayWasRequested = true
        }
    }

    // MARK: - Private Methods

    /// Legacy method for evaluating player commands - now delegates to SingletonPlayerWebView.
    private func evaluatePlayerCommand(_ command: String) async {
        // Commands are now routed through SingletonPlayerWebView
        switch command {
        case "pause", "pauseVideo()":
            SingletonPlayerWebView.shared.pause()
        case "play", "playVideo()":
            SingletonPlayerWebView.shared.play()
        default:
            if command.hasPrefix("seekTo(") {
                let timeStr = command.dropFirst(7).prefix(while: { $0 != "," && $0 != ")" })
                if let time = Double(timeStr) {
                    SingletonPlayerWebView.shared.seek(to: time)
                }
            } else if command.hasPrefix("setVolume(") {
                let volStr = command.dropFirst(10).dropLast()
                if let vol = Int(volStr) {
                    SingletonPlayerWebView.shared.setVolume(Double(vol) / 100.0)
                }
            }
        }
    }
}
