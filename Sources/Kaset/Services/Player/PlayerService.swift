// swiftlint:disable file_length

import Foundation
import Observation
import os

// MARK: - PlayerService

/// Controls music playback via a hidden WKWebView.
@MainActor
@Observable
final class PlayerService: NSObject, PlayerServiceProtocol {
    @ObservationIgnored var currentWebPlaybackVideoId: @MainActor () -> String? = {
        SingletonPlayerWebView.shared.currentVideoId
    }

    @ObservationIgnored var currentMusicPlaybackSnapshot: @MainActor () async -> SingletonPlayerWebView.PlaybackSnapshot? = {
        await SingletonPlayerWebView.shared.currentPlaybackSnapshot()
    }

    @ObservationIgnored var smartShuffleFeatureEnabled: @MainActor () -> Bool = {
        SettingsManager.shared.smartShuffleEnabled
    }

    @ObservationIgnored var queuePersistenceDefaults: UserDefaults = .standard

    @ObservationIgnored var onMusicPlaybackNavigationRequested: ((String, Bool) -> Void)?

    /// Latest media occurrence observed or initiated for Music playback.
    @ObservationIgnored private(set) var currentMusicPlaybackOccurrence: MusicPlaybackOccurrence?

    @ObservationIgnored private var nativeMusicPlaybackGeneration: UInt64 = 0
    @ObservationIgnored private var lastClaimedNativeMusicPlaybackGeneration: UInt64 = 0
    @ObservationIgnored private var lastClaimedWebMusicPlaybackOccurrence: MusicPlaybackOccurrence?

    var currentNativeMusicPlaybackGeneration: UInt64 {
        self.currentMusicPlaybackOccurrence?.nativeGeneration ?? self.nativeMusicPlaybackGeneration
    }

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

    /// Shuffle mode for playback. `smart` interleaves recommended tracks.
    enum ShuffleMode: String, CaseIterable, Codable {
        case off
        case on
        case smart
    }

    /// How the mini player was opened.
    enum MiniPlayerMode: Equatable {
        /// Mini player floats alongside the main app window.
        case auxiliary
        /// Mini player replaces the main app window until it closes.
        case switchFromMainWindow
    }

    /// Visible mini player content size.
    enum MiniPlayerPanel: Equatable {
        case compact
        case expanded
        case lyrics
    }

    // MARK: - Observable State

    /// Current playback state.
    var state: PlaybackState = .idle

    /// Native play/pause intent survives transient ad buffering/pauses where
    /// observable transport state is not authoritative for recovery.
    var shouldResumeAfterInterruption = false
    var isStoppingPlayback = false

    var isAwaitingPlaybackConfirmation = false
    var isExplicitPauseIntentActive = false

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

    /// Explicit native playback clock mirror used by restoration/history transitions.
    /// Synced-lyrics rendering uses `currentLyricsDisplayTimeMs` instead.
    var currentTimeMs = 0

    /// Current synced-lyrics line index, updated only when the displayed lyric line changes.
    var currentLyricsLineIndex: Int?

    /// Representative playback timestamp for synced lyrics display state.
    /// Updated with the line index, not at raw playback cadence.
    var currentLyricsDisplayTimeMs: Int?

    /// Total duration of current track in seconds.
    var duration: TimeInterval = 0

    /// Whether the music playback WebView currently reports an advertisement.
    var isShowingAd = false

    /// Last clock sample known to belong to the requested music content.
    var lastNonAdContentProgress: TimeInterval = 0

    /// Video identity owning `lastNonAdContentProgress`.
    var lastNonAdContentVideoId: String?

    /// Video ID carried by the latest playback-state bridge update. This gives consumers
    /// provenance for `progress`/`duration`, which can otherwise remain stale across track changes.
    private(set) var playbackStateVideoId: String?

    /// Monotonic identity for playback-state bridge observations. Consumers use this to distinguish
    /// a fresh same-video sample from progress/duration left behind by an earlier metadata identity.
    private(set) var playbackStateObservationSequence = 0

    func setPlaybackStateVideoId(_ videoId: String?) {
        self.playbackStateVideoId = videoId
    }

    func recordPlaybackStateObservation(videoId: String?) {
        self.playbackStateObservationSequence &+= 1
        self.playbackStateVideoId = videoId
    }

    /// Current volume (0.0 - 1.0).
    var volume: Double = 1.0

    /// Volume before muting, for unmute restoration.
    private(set) var volumeBeforeMute: Double = 1.0

    /// Whether audio is currently muted.
    var isMuted: Bool {
        self.volume == 0
    }

    /// Current shuffle mode (off / on / smart).
    var shuffleMode: ShuffleMode = .off

    /// Whether any shuffle (plain or smart) is active. Computed shim so existing
    /// readers (WebQueueSync, UI, scripting, protocol) keep working unchanged.
    var shuffleEnabled: Bool {
        self.shuffleMode != .off
    }

    /// True while the rest of a playlist is still loading into the queue after playback
    /// started. Smart Shuffle defers suggestion generation until this clears, so candidates
    /// dedup against the complete playlist instead of only the first loaded batch.
    var isQueueLoading: Bool = false

    /// Monotonic token identifying the current deferred-load stream. Bumped whenever a new
    /// playback replaces the queue, so a stale deferred load (e.g. a playlist still paging when
    /// the user starts a different one) can detect it has been superseded and stand down instead
    /// of clobbering the new playback's loading state. Not observed by the UI.
    @ObservationIgnored var queueLoadGeneration = 0

    /// Current repeat mode.
    private(set) var repeatMode: RepeatMode = .off

    /// Playback queue.
    private var queueStorage: [QueueEntry] = []

    /// Set when guest-startup privacy cleanup empties visible queue state but
    /// must not delete a saved guest queue/session on the next persistence pass.
    var suppressNextEmptyQueuePersistence = false

    /// Ownership scope restored from the persisted playback session payload.
    /// `nil` means legacy/unknown and must not be trusted across guest privacy boundaries.
    var restoredPlaybackSessionOwnerScope: String?

    static let playbackSessionScopeGuest = "guest"
    static let playbackSessionScopeAuthenticated = "authenticated"
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

    /// Queue occurrence currently represented by active Web media.
    var activePlaybackQueueEntryID: UUID?

    /// Whether the mini player should be shown (user needs to interact to start playback).
    var showMiniPlayer: Bool = false

    /// Whether the native mini player window is visible.
    var isMiniPlayerVisible: Bool = false

    /// How the native mini player was opened.
    var miniPlayerMode: MiniPlayerMode = .auxiliary

    /// Which mini player layout is active.
    var miniPlayerPanel: MiniPlayerPanel = .compact

    /// Whether closing the mini player should restore the main window.
    var shouldRestoreMainWindowWhenMiniPlayerCloses: Bool = false

    /// A consumed-on-read restore request created when a switched mini player closes.
    var miniPlayerMainWindowRestoreRequest: Bool = false

    /// The video ID that needs to be played in the mini player.
    var pendingPlayVideoId: String?

    /// Whether the user has successfully interacted at least once this session.
    /// After first successful playback, we can auto-play without showing the popup.
    private(set) var hasUserInteractedThisSession: Bool = false

    /// Saved seek position to apply once a restored session finishes loading.
    var pendingRestoredSeek: TimeInterval?

    /// Whether a restored session is waiting for an explicit user-triggered load.
    var isPendingRestoredLoadDeferred: Bool = false

    /// Whether the deferred restored load must force a full page navigation even
    /// when the same video ID is already present in the WebView.
    var shouldForcePendingRestoredLoad: Bool = false

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
    var authService: AuthService?
    var songLikeStatusManager = SongLikeStatusManager.shared

    /// Continuation token for loading more songs in infinite mix/radio.
    var mixContinuationToken: String?
    var mixContinuationRequiresAuth = false
    var musicPlaybackIntentGeneration: UInt64 = 0
    var musicPlaybackReservationGeneration: UInt64 = 0
    var musicPlaybackIntentIssuedAtMilliseconds: Double = 0
    var musicPlaybackIntentAcceptsPriorTerminalEvent = false
    var musicPlaybackMinimumAcceptedTerminalIntentGeneration: UInt64 = 0
    var libraryMutationGeneration: UInt64 = 0
    var libraryMutationRevisionCounter: UInt64 = 0
    var libraryMutationRevisions: [String: UInt64] = [:]
    var confirmedLibraryStateByKey: [String: MusicLibraryConfirmedState] = [:]
    var pendingLibraryMutationCountsByKey: [String: Int] = [:]
    var accountSessionGeneration: UInt64 = 0
    @ObservationIgnored var libraryMutationTails: [String: Task<Result<Void, any Error>, Never>] = [:]
    @ObservationIgnored var libraryMutationTailGenerations: [String: UInt64] = [:]
    @ObservationIgnored var remoteMusicTransportCommands: [MusicRemoteTransportCommand] = []
    @ObservationIgnored var remoteMusicTransportCommandReadIndex = 0
    @ObservationIgnored var remoteMusicTransportTask: Task<Void, Never>?
    @ObservationIgnored var remoteMusicTransportBatchGeneration: UInt64 = 0
    @ObservationIgnored var remoteMusicTransportIntent: MusicPlaybackIntent?
    @ObservationIgnored var remoteMusicSkipTarget: TimeInterval?
    @ObservationIgnored var remoteMusicSkipVideoID: String?
    @ObservationIgnored var remoteMusicSkipQueueEntryID: UUID?
    @ObservationIgnored var remoteMusicSkipAdmittedAt: ContinuousClock.Instant?
    @ObservationIgnored var remoteMusicMetadataFollowUpTask: Task<Void, Never>?
    @ObservationIgnored var remoteMusicMetadataFollowUpGeneration: UInt64 = 0
    @ObservationIgnored var remoteMusicQueueFollowUpTask: Task<Void, Never>?
    @ObservationIgnored var remoteMusicQueueFollowUpGeneration: UInt64 = 0

    /// Whether we're currently fetching more mix songs.
    var isFetchingMoreMixSongs: Bool = false
    var activeMixContinuationRequestID: UUID?
    var mixContinuationWaiters: [CheckedContinuation<Void, Never>] = []

    /// Smart Shuffle: videoIds suggested this session, for dedup across fills.
    var smartShuffleSeenSuggestionIds: Set<String> = []

    /// Smart Shuffle: seed videoIds whose radio yielded nothing new, so the filler skips them.
    var smartShuffleExhaustedSeeds: Set<String> = []

    /// Whether the smart-shuffle window filler is running (also drives the player-bar progress hint).
    var isApplyingSmartShuffle: Bool = false

    /// The in-flight suggestion fill, if any. A single stored task coalesces concurrent callers
    /// (mode cycling, rapid advances) onto one fill loop and lets a queue replacement cancel a
    /// stale fill, replacing the old fire-and-forget `Task {}` + boolean re-entrancy guard.
    @ObservationIgnored var smartShuffleFillTask: Task<Void, Never>?

    /// Monotonic token for the current fill. `Task` is a value type (no identity), so the spawner
    /// captures this epoch and only clears the shared task/hint if it still owns them — a cancel or
    /// a newer fill bumps the epoch so a stale spawner cannot stomp the live one.
    @ObservationIgnored var smartShuffleFillEpoch = 0

    /// UserDefaults key for persisting queue display mode.
    static let queueDisplayModeKey = "kaset.queue.displayMode"

    /// Undo/redo history for queue (up to 10 states). In-memory only.
    var queueUndoHistory: [QueueState] = []
    var queueRedoHistory: [QueueState] = []
    static let queueUndoMaxCount = 10

    /// Queue index before each `next()`; `previous()` pops so Back returns to the track you skipped from (shuffle- and seek-safe).
    private var forwardSkipIndexStack: [Int] = []

    /// Queue order captured when shuffle is enabled, used to restore the visible queue when shuffle is disabled.
    var queueOrderBeforeShuffle: [QueueEntry]?

    /// UserDefaults key for persisting volume.
    static let volumeKey = "playerVolume"
    /// UserDefaults key for persisting volume before mute.
    static let volumeBeforeMuteKey = "playerVolumeBeforeMute"
    /// UserDefaults key for persisting shuffle state.
    static let shuffleEnabledKey = "playerShuffleEnabled"
    /// UserDefaults key for persisting the tri-state shuffle mode.
    static let shuffleModeKey = "playerShuffleMode"
    /// UserDefaults key for persisting repeat mode.
    static let repeatModeKey = "playerRepeatMode"

    /// Last playback-session signature written in this process, used to skip redundant UserDefaults writes.
    @ObservationIgnored var lastSavedPlaybackSessionSignature: Data?

    @ObservationIgnored var queuePersistenceWriteCountForTesting = 0

    /// Optional suffix for test-only queue persistence isolation. Production uses the empty suffix.
    @ObservationIgnored var queuePersistenceKeySuffix = ""

    /// Task handle for the one-shot queue metadata enrichment pass, if one is scheduled or running.
    @ObservationIgnored var enrichmentTask: Task<Void, Never>?

    /// Delay used to coalesce queue mutations before the one-shot metadata enrichment pass runs.
    @ObservationIgnored var queueEnrichmentInitialDelay: Duration = .seconds(2)

    /// Delay used before retrying entries that remain incomplete after a scheduled enrichment pass.
    @ObservationIgnored var queueEnrichmentRetryDelay: Duration = .seconds(30)

    /// Maximum scheduled enrichment attempts per stable queue entry before waiting for another queue event.
    static let maxQueueEnrichmentAttempts = 3

    /// Scheduled enrichment attempts by stable queue entry identity.
    @ObservationIgnored var queueEnrichmentAttemptsByEntryID: [UUID: Int] = [:]

    /// Monotonic token used to prevent stale scheduled enrichment tasks from clearing a newer task.
    @ObservationIgnored var queueEnrichmentGeneration = 0

    /// True while the one-shot enrichment pass is actively fetching metadata.
    @ObservationIgnored var isQueueEnrichmentRunning = false

    /// Generation of the currently running enrichment pass, if any.
    @ObservationIgnored var queueEnrichmentRunningGeneration: Int?

    /// Set when an external queue mutation happens while enrichment is running.
    @ObservationIgnored var queueEnrichmentNeedsReschedule = false

    /// Suppresses scheduler churn for queue writes that are produced by the enrichment pass itself.
    @ObservationIgnored var isApplyingQueueEnrichmentResult = false

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
            if let savedMode = UserDefaults.standard.string(forKey: Self.shuffleModeKey),
               let mode = ShuffleMode(rawValue: savedMode)
            {
                self.shuffleMode = mode
                self.logger.info("Restored shuffle mode: \(self.shuffleMode.rawValue)")
            } else if UserDefaults.standard.object(forKey: Self.shuffleEnabledKey) != nil {
                // Legacy migration: map the old bool to the new tri-state.
                self.shuffleMode = UserDefaults.standard.bool(forKey: Self.shuffleEnabledKey) ? .on : .off
                self.logger.info("Migrated legacy shuffle state to mode: \(self.shuffleMode.rawValue)")
            }

            // Don't resurrect smart mode if the feature has since been disabled in settings;
            // fall back to plain shuffle (the user still wanted shuffle, just not suggestions).
            self.shuffleMode = Self.resolvedShuffleMode(
                self.shuffleMode,
                smartShuffleEnabled: self.smartShuffleFeatureEnabled()
            )

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

        // Queue metadata enrichment is event/one-shot driven; this only schedules if restored
        // state already needs enrichment and a client is available.
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
        if let activePlaybackQueueEntryID,
           !entries.contains(where: { $0.id == activePlaybackQueueEntryID })
        {
            self.activePlaybackQueueEntryID = nil
        }
        self.synchronizeCurrentQueueEntryID()
        self.queueDidChangeForEnrichment()
    }

    func synchronizeCurrentQueueEntryID() {
        self.currentQueueEntryID = self.queueStorage[safe: self.currentIndex]?.id
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
            let hasVideo = dict["hasVideo"] as? Bool
            self.currentTrack = Song(
                id: id,
                title: title,
                artists: [Artist(id: "mock-artist", name: artist)],
                album: nil,
                duration: duration,
                thumbnailURL: nil,
                videoId: videoId,
                hasVideo: hasVideo
            )
            if let hasVideo {
                self.currentTrackHasVideo = hasVideo
            }
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

    /// Sets the like-status cache used by playback metadata and rating actions.
    func setSongLikeStatusManager(_ manager: SongLikeStatusManager) {
        self.songLikeStatusManager = manager
    }

    /// Sets the YTMusicClient for API calls (dependency injection).
    func setYTMusicClient(_ client: any YTMusicClientProtocol) {
        self.ytMusicClient = client
        self.resetQueueEnrichmentAttemptState()
        self.scheduleQueueEnrichmentIfNeeded()
    }

    /// Sets the AuthService used to guard account-scoped mutations.
    func setAuthService(_ authService: AuthService) {
        self.authService = authService
    }

    /// Account-backed library/rating mutations should be no-ops in guest mode.
    var canPerformAccountMutation: Bool {
        self.authService?.hasPersonalAccount ?? false
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

    /// Starts a native fallback occurrence until the Web observer binds the
    /// corresponding document/media occurrence.
    @discardableResult
    func beginNativeMusicPlaybackOccurrence(
        videoId: String? = nil,
        synchronizeCurrentDocument: Bool = false
    ) -> MusicPlaybackOccurrence {
        self.nativeMusicPlaybackGeneration = max(
            self.nativeMusicPlaybackGeneration,
            self.currentMusicPlaybackOccurrence?.nativeGeneration ?? 0
        )
        self.nativeMusicPlaybackGeneration &+= 1
        let occurrence = MusicPlaybackOccurrence.native(
            generation: self.nativeMusicPlaybackGeneration,
            videoId: videoId
        )
        self.currentMusicPlaybackOccurrence = occurrence
        if synchronizeCurrentDocument {
            SingletonPlayerWebView.shared.setNativePlaybackGeneration(
                occurrence.nativeGeneration
            )
        }
        return occurrence
    }

    /// A terminal transition can be claimed before the Web observer binds its
    /// document/media occurrence. Resuming that media is a new playback, so it
    /// needs a fresh native generation and the active document must publish it.
    @discardableResult
    func beginNativeMusicPlaybackReplayIfNeeded() -> MusicPlaybackOccurrence? {
        guard let currentMusicPlaybackOccurrence else { return nil }
        let wasConsumed = if currentMusicPlaybackOccurrence.documentGeneration == nil {
            currentMusicPlaybackOccurrence.mediaGeneration
                <= self.lastClaimedNativeMusicPlaybackGeneration
        } else if let lastClaimedWebMusicPlaybackOccurrence {
            !Self.isWebMusicPlaybackOccurrence(
                currentMusicPlaybackOccurrence,
                newerThan: lastClaimedWebMusicPlaybackOccurrence
            )
        } else {
            false
        }
        guard wasConsumed else { return nil }

        return self.beginNativeMusicPlaybackOccurrence(
            videoId: self.currentTrack?.videoId
                ?? self.pendingPlayVideoId
                ?? currentMusicPlaybackOccurrence.videoId,
            synchronizeCurrentDocument: true
        )
    }

    func resetMusicPlaybackOccurrenceState() {
        self.currentMusicPlaybackOccurrence = nil
        self.lastClaimedWebMusicPlaybackOccurrence = nil
    }

    /// Binds the active native playback state to an observer-issued occurrence.
    /// Older or already-terminal Web occurrences cannot replace a newer replay.
    @discardableResult
    func bindWebMusicPlaybackOccurrence(
        documentGeneration: UInt64,
        mediaGeneration: UInt64,
        nativeGeneration: UInt64 = 0,
        videoId: String? = nil
    ) -> MusicPlaybackOccurrence? {
        guard mediaGeneration > 0 else { return self.currentMusicPlaybackOccurrence }
        let occurrence = MusicPlaybackOccurrence.web(
            documentGeneration: documentGeneration,
            mediaGeneration: mediaGeneration,
            nativeGeneration: nativeGeneration,
            videoId: videoId
        )
        let nativeOccurrence = self.currentMusicPlaybackOccurrence.flatMap {
            $0.documentGeneration == nil ? $0 : nil
        }
        if self.songNearingEnd,
           let currentMusicPlaybackOccurrence,
           currentMusicPlaybackOccurrence.documentGeneration != nil,
           Self.isWebMusicPlaybackOccurrence(
               occurrence,
               newerThan: currentMusicPlaybackOccurrence
           )
        {
            return nil
        }
        if let nativeOccurrence,
           occurrence.nativeGeneration < nativeOccurrence.nativeGeneration
        {
            return nil
        }
        let hasConfirmedVideoMismatch = if let nativeVideoId = nativeOccurrence?.videoId,
                                           let videoId
        {
            nativeVideoId != videoId
        } else {
            false
        }
        let inheritsConsumedNativeOccurrence = if let nativeOccurrence {
            occurrence.nativeGeneration == nativeOccurrence.nativeGeneration
                && !hasConfirmedVideoMismatch
                && nativeOccurrence.mediaGeneration
                <= self.lastClaimedNativeMusicPlaybackGeneration
        } else {
            false
        }

        if let lastClaimedWebMusicPlaybackOccurrence,
           !Self.isWebMusicPlaybackOccurrence(
               occurrence,
               newerThan: lastClaimedWebMusicPlaybackOccurrence
           )
        {
            return nil
        }

        if let currentMusicPlaybackOccurrence,
           currentMusicPlaybackOccurrence.documentGeneration != nil,
           !Self.isWebMusicPlaybackOccurrence(
               occurrence,
               newerThanOrEqualTo: currentMusicPlaybackOccurrence
           )
        {
            return nil
        }

        self.currentMusicPlaybackOccurrence = occurrence
        if inheritsConsumedNativeOccurrence {
            self.lastClaimedWebMusicPlaybackOccurrence = occurrence
        }
        return occurrence
    }

    func acceptsWebMusicPlaybackOccurrence(_ occurrence: MusicPlaybackOccurrence) -> Bool {
        if let currentMusicPlaybackOccurrence {
            if currentMusicPlaybackOccurrence.documentGeneration == nil {
                guard occurrence.nativeGeneration >= currentMusicPlaybackOccurrence.nativeGeneration else {
                    return false
                }
                let hasConfirmedVideoMismatch = if let nativeVideoId = currentMusicPlaybackOccurrence.videoId,
                                                   let webVideoId = occurrence.videoId
                {
                    nativeVideoId != webVideoId
                } else {
                    false
                }
                if occurrence.nativeGeneration == currentMusicPlaybackOccurrence.nativeGeneration,
                   !hasConfirmedVideoMismatch,
                   currentMusicPlaybackOccurrence.mediaGeneration
                   <= self.lastClaimedNativeMusicPlaybackGeneration
                {
                    return false
                }
            } else if !Self.isWebMusicPlaybackOccurrence(
                occurrence,
                newerThanOrEqualTo: currentMusicPlaybackOccurrence
            ) {
                return false
            }
        }

        if let lastClaimedWebMusicPlaybackOccurrence,
           !Self.isWebMusicPlaybackOccurrence(
               occurrence,
               newerThan: lastClaimedWebMusicPlaybackOccurrence
           )
        {
            return false
        }
        return true
    }

    /// Atomically consumes one terminal transition for one playback occurrence.
    /// Main-actor isolation makes the check-and-record indivisible with respect
    /// to near-end, natural-ended, and manual-ended callers.
    func claimTerminalMusicPlaybackOccurrence(_ occurrence: MusicPlaybackOccurrence?) -> Bool {
        let resolvedOccurrence = occurrence
            ?? self.currentMusicPlaybackOccurrence
            ?? self.beginNativeMusicPlaybackOccurrence(
                videoId: self.currentTrack?.videoId ?? self.pendingPlayVideoId
            )

        if resolvedOccurrence.documentGeneration == nil {
            if let currentMusicPlaybackOccurrence {
                guard currentMusicPlaybackOccurrence.documentGeneration == nil,
                      resolvedOccurrence.nativeGeneration >= currentMusicPlaybackOccurrence.nativeGeneration
                else {
                    return false
                }
            }
            guard resolvedOccurrence.mediaGeneration > self.lastClaimedNativeMusicPlaybackGeneration else {
                return false
            }
            self.lastClaimedNativeMusicPlaybackGeneration = resolvedOccurrence.mediaGeneration
            return true
        }

        if let currentNativeOccurrence = self.currentMusicPlaybackOccurrence,
           currentNativeOccurrence.documentGeneration == nil
        {
            guard resolvedOccurrence.nativeGeneration >= currentNativeOccurrence.nativeGeneration else {
                return false
            }
            if resolvedOccurrence.nativeGeneration == currentNativeOccurrence.nativeGeneration,
               currentNativeOccurrence.mediaGeneration <= self.lastClaimedNativeMusicPlaybackGeneration
            {
                return false
            }
        }

        if let currentWebOccurrence = self.currentMusicPlaybackOccurrence,
           currentWebOccurrence.documentGeneration != nil,
           !Self.isWebMusicPlaybackOccurrence(
               resolvedOccurrence,
               newerThanOrEqualTo: currentWebOccurrence
           )
        {
            return false
        }

        if let lastClaimedWebMusicPlaybackOccurrence,
           !Self.isWebMusicPlaybackOccurrence(
               resolvedOccurrence,
               newerThan: lastClaimedWebMusicPlaybackOccurrence
           )
        {
            return false
        }
        self.lastClaimedWebMusicPlaybackOccurrence = resolvedOccurrence
        return true
    }

    private static func isWebMusicPlaybackOccurrence(
        _ occurrence: MusicPlaybackOccurrence,
        newerThan other: MusicPlaybackOccurrence
    ) -> Bool {
        guard let documentGeneration = occurrence.documentGeneration,
              let otherDocumentGeneration = other.documentGeneration
        else {
            return false
        }
        if documentGeneration != otherDocumentGeneration {
            return documentGeneration > otherDocumentGeneration
        }
        if occurrence.mediaGeneration != other.mediaGeneration {
            return occurrence.mediaGeneration > other.mediaGeneration
        }
        return occurrence.nativeGeneration > other.nativeGeneration
    }

    private static func isWebMusicPlaybackOccurrence(
        _ occurrence: MusicPlaybackOccurrence,
        newerThanOrEqualTo other: MusicPlaybackOccurrence
    ) -> Bool {
        occurrence == other || self.isWebMusicPlaybackOccurrence(occurrence, newerThan: other)
    }
}
