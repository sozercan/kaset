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

    /// Artist-page episode backing the current playback, when applicable.
    var currentEpisode: ArtistEpisode?

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
    var volume: Double = 1.0

    /// Volume before muting, for unmute restoration.
    private(set) var volumeBeforeMute: Double = 1.0

    /// Whether audio is currently muted.
    var isMuted: Bool {
        self.volume == 0
    }

    /// Whether shuffle mode is enabled.
    var shuffleEnabled: Bool = false

    /// Current repeat mode.
    private(set) var repeatMode: RepeatMode = .off

    /// Playback queue.
    private var queueStorage: [QueueEntry] = []
    var queue: [Song] {
        self.queueStorage.map(\.song)
    }

    var queueEntryIDs: [UUID] {
        self.queueStorage.map(\.id)
    }

    var queueEntries: [QueueEntry] {
        self.queueStorage
    }

    /// Index of current track in queue.
    var currentIndex: Int = 0 {
        didSet {
            self.synchronizeCurrentQueueEntryID()
        }
    }

    private(set) var currentQueueEntryID: UUID?

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
    var isAirPlayConnected: Bool = false

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
    private var queueUndoHistory: [QueueState] = []
    private var queueRedoHistory: [QueueState] = []
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

    // MARK: - Controlled Mutators

    /// Stores the pre-mute volume through a narrow API instead of exposing a writable property.
    func rememberVolumeBeforeMute(_ value: Double) {
        let normalizedValue = value > 0 ? value : 1.0
        self.volumeBeforeMute = normalizedValue
        UserDefaults.standard.set(normalizedValue, forKey: Self.volumeBeforeMuteKey)
    }

    /// Advances the repeat mode and persists it when playback settings are remembered.
    func advanceRepeatMode() {
        self.repeatMode = switch self.repeatMode {
        case .off:
            .all
        case .all:
            .one
        case .one:
            .off
        }

        guard SettingsManager.shared.rememberPlaybackSettings else { return }

        let modeString = switch self.repeatMode {
        case .off: "off"
        case .all: "all"
        case .one: "one"
        }
        UserDefaults.standard.set(modeString, forKey: Self.repeatModeKey)
    }

    /// Records that playback has succeeded after a user gesture in this app session.
    func markUserInteractedThisSession() {
        self.hasUserInteractedThisSession = true
    }

    /// Records that the user explicitly requested AirPlay in this app session.
    func markAirPlayRequested() {
        self.airPlayWasRequested = true
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
        let state = QueueState(entries: self.queueEntries, currentIndex: self.currentIndex)
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
        self.queueRedoHistory.append(QueueState(entries: self.queueEntries, currentIndex: self.currentIndex))
        self.setQueue(entries: state.entries)
        self.currentIndex = min(state.currentIndex, max(0, state.entries.count - 1))
        self.saveQueueForPersistence()
        self.logger.info("Undid queue to \(state.entries.count) songs at index \(self.currentIndex)")
        self.clearForwardSkipNavigationStack()
    }

    /// Restores the next queue state after an undo. Does nothing if redo history is empty.
    func redoQueue() {
        guard let state = self.queueRedoHistory.popLast() else { return }
        self.queueUndoHistory.append(QueueState(entries: self.queueEntries, currentIndex: self.currentIndex))
        self.setQueue(entries: state.entries)
        self.currentIndex = min(state.currentIndex, max(0, state.entries.count - 1))
        self.saveQueueForPersistence()
        self.logger.info("Redid queue to \(state.entries.count) songs at index \(self.currentIndex)")
        self.clearForwardSkipNavigationStack()
    }

    /// Clears forward-skip undo when the queue is replaced or reordered so indices are not stale.
    func clearForwardSkipNavigationStack() {
        self.forwardSkipIndexStack.removeAll()
    }

    func setQueue(_ songs: [Song], entryIDs: [UUID]? = nil) {
        let entries = zip(entryIDs ?? songs.map { _ in UUID() }, songs).map { QueueEntry(id: $0.0, song: $0.1) }
        self.setQueue(entries: entries.count == songs.count ? entries : songs.map { QueueEntry(id: UUID(), song: $0) })
    }

    func setQueue(entries: [QueueEntry]) {
        self.queueStorage = entries
        self.synchronizeCurrentQueueEntryID()
    }

    func synchronizeCurrentQueueEntryID() {
        self.currentQueueEntryID = self.queueEntries[safe: self.currentIndex]?.id
    }

    /// Records the current index before `next()` moves to `newIndex` (no-op if unchanged).
    func pushForwardSkipStackIfLeavingIndex(for newIndex: Int) {
        let from = self.currentIndex
        guard from != newIndex else { return }
        self.forwardSkipIndexStack.append(from)
    }

    /// Returns and removes the most recent index saved before a forward skip.
    func popForwardSkipIndex() -> Int? {
        self.forwardSkipIndexStack.popLast()
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

    /// Flag to track when a song is nearing its end.
    var songNearingEnd: Bool = false

    /// Flag to track when we initiated a track change (to correct YouTube's autoplay interference).
    /// This is set when we call play() and cleared after the track loads.
    var isKasetInitiatedPlayback: Bool = false

    /// Flag to suppress YouTube autoplay after the native queue has finished.
    var shouldSuppressAutoplayAfterQueueEnd: Bool = false

    /// Grace period instant - don't auto-close video window shortly after opening (uses monotonic clock)
    var videoWindowOpenedAt: ContinuousClock.Instant?

    /// Debounces repeat-one recovery `play()` when YouTube sends bursty metadata (safety net in `PlayerService+WebQueueSync`).
    /// Internal so the WebQueueSync extension can throttle; not part of the public API.
    var lastRepeatOneRecoveryInstant: ContinuousClock.Instant?
}
