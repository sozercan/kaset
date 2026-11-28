// swiftlint:disable file_length

import Foundation
import Observation
import os

enum NativeQueueMaintenanceContext {
    @TaskLocal static var isApplyingQueueMutation = false
}

@MainActor
@Observable
// swiftlint:disable:next type_body_length
final class PlayerService: NSObject, PlayerServiceProtocol {
    @ObservationIgnored var currentWebPlaybackVideoId: @MainActor () -> String? = {
        SingletonPlayerWebView.shared.currentVideoId
    }

    @ObservationIgnored var currentMusicPlaybackSnapshot: @MainActor () async -> SingletonPlayerWebView.PlaybackSnapshot? = {
        await SingletonPlayerWebView.shared.currentPlaybackSnapshot()
    }

    @ObservationIgnored var applyMusicPlaybackVolume: @MainActor (Double) -> Void = {
        SingletonPlayerWebView.shared.setVolume($0)
    }

    @ObservationIgnored var smartShuffleFeatureEnabled: @MainActor () -> Bool = {
        SettingsManager.shared.smartShuffleEnabled
    }

    @ObservationIgnored var smartShuffleConfigProvider: @MainActor () -> SmartShuffleConfig = {
        SmartShuffleConfig(
            suggestEveryN: SettingsManager.shared.smartShuffleSuggestEveryN,
            burst: SettingsManager.shared.smartShuffleBurst,
            suggestionsAhead: SettingsManager.shared.smartShuffleSuggestionsAhead
        )
    }

    @ObservationIgnored var queuePersistenceDefaults: UserDefaults = .standard

    @ObservationIgnored var onMusicPlaybackNavigationRequested: ((String, Bool) -> Void)?

    @ObservationIgnored private(set) var currentMusicPlaybackOccurrence: MusicPlaybackOccurrence?

    @ObservationIgnored private var nativeMusicPlaybackGeneration: UInt64 = 0
    @ObservationIgnored private var lastClaimedNativeMusicPlaybackGeneration: UInt64 = 0
    @ObservationIgnored private var lastClaimedWebMusicPlaybackOccurrence: MusicPlaybackOccurrence?

    var currentNativeMusicPlaybackGeneration: UInt64 {
        self.currentMusicPlaybackOccurrence?.nativeGeneration ?? self.nativeMusicPlaybackGeneration
    }

    static var shared: PlayerService?
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

    enum RepeatMode {
        case off
        case all
        case one
    }

    enum ShuffleMode: String, CaseIterable, Codable {
        case off
        case on
        case smart
    }

    enum MiniPlayerMode: Equatable {
        case auxiliary
        case switchFromMainWindow
    }

    enum MiniPlayerPanel: Equatable {
        case compact
        case expanded
        case lyrics
    }

    var state: PlaybackState = .idle

    var shouldResumeAfterInterruption = false
    var isStoppingPlayback = false

    var isAwaitingPlaybackConfirmation = false
    var isExplicitPauseIntentActive = false

    @ObservationIgnored var routeLossPauseAt: ContinuousClock.Instant?

    @ObservationIgnored var unattributedRemotePauseAt: ContinuousClock.Instant?

    @ObservationIgnored var hasAudioRouteReturned: @MainActor (ContinuousClock.Instant) -> Bool = {
        DefaultOutputDeviceMonitor.shared.routeRestored(since: $0)
    }

    @ObservationIgnored var claimsRouteLossPause: @MainActor (ContinuousClock.Instant) -> Bool = {
        DefaultOutputDeviceMonitor.shared.claimRouteLossPause(
            admittedAt: $0,
            within: NowPlayingManager.routeLossPauseWindow
        )
    }

    var currentTrack: Song? {
        didSet {
            self.driveNowPlayingTracklistProvider()
        }
    }

    @ObservationIgnored private var durationObservation: (videoId: String, duration: TimeInterval)?
    @ObservationIgnored var isApplyingPlaybackStateObservation = false

    var currentEpisode: ArtistEpisode?

    var isPlaying: Bool {
        self.state.isPlaying
    }

    var progress: TimeInterval = 0

    var currentTimeMs = 0

    var currentLyricsLineIndex: Int?

    var currentLyricsDisplayTimeMs: Int?

    var duration: TimeInterval = 0 {
        didSet {
            guard !self.isApplyingPlaybackStateObservation else { return }
            self.driveNowPlayingTracklistProvider()
        }
    }

    var isShowingAd = false {
        didSet {
            if self.isShowingAd != oldValue {
                self.adPlaybackStateGeneration &+= 1
            }
            if !self.isShowingAd {
                self.lastAdPlaybackProgress = nil
                self.lastAdPlaybackProgressAt = nil
            }
        }
    }

    var lastAdPlaybackProgress: TimeInterval?
    var lastAdPlaybackProgressAt: ContinuousClock.Instant?

    @ObservationIgnored private(set) var adPlaybackStateGeneration = 0

    var lastNonAdContentProgress: TimeInterval = 0

    var lastNonAdContentVideoId: String?

    private(set) var playbackStateVideoId: String?

    private(set) var playbackStateObservationSequence = 0

    func setPlaybackStateVideoId(_ videoId: String?) {
        self.playbackStateVideoId = self.normalizedPlaybackVideoId(videoId)
    }

    func recordPlaybackStateObservation(videoId: String?) {
        self.playbackStateObservationSequence &+= 1
        self.playbackStateVideoId = self.normalizedPlaybackVideoId(videoId)
    }

    func recordPlaybackStateObservation(videoId: String?, duration: TimeInterval) {
        self.recordPlaybackStateObservation(videoId: videoId)
        self.recordDurationObservation(videoId: self.playbackStateVideoId, duration: duration)
    }

    func normalizedPlaybackVideoId(_ videoId: String?) -> String? {
        guard let normalized = videoId?.trimmingCharacters(in: .whitespacesAndNewlines), !normalized.isEmpty else {
            return nil
        }
        return normalized
    }

    func bestKnownDuration(for track: Song?) -> TimeInterval {
        guard let track else { return 0 }
        if let durationObservation, durationObservation.videoId == track.videoId {
            return durationObservation.duration
        }
        return self.positiveMetadataDuration(for: track)
    }

    func positiveMetadataDuration(for track: Song?) -> TimeInterval {
        track?.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
    }

    func observedDuration(for videoId: String) -> TimeInterval? {
        guard let durationObservation, durationObservation.videoId == videoId else { return nil }
        return durationObservation.duration
    }

    func recordDurationObservation(videoId: String?, duration: TimeInterval) {
        if let videoId, duration.isFinite, duration > 0 {
            self.durationObservation = (videoId, duration)
        }
        self.driveNowPlayingTracklistProvider()
    }

    private func driveNowPlayingTracklistProvider() {
        let observedDuration = self.currentTrack.flatMap {
            self.observedDuration(for: $0.videoId)
        } ?? 0
        self.nowPlayingTracklistProvider?.update(
            track: self.currentTrack,
            duration: observedDuration
        )
    }

    var volume: Double = 1.0

    private(set) var volumeBeforeMute: Double = 1.0

    var isMuted: Bool {
        self.volume == 0
    }

    var shuffleMode: ShuffleMode = .off

    var shuffleEnabled: Bool {
        self.shuffleMode != .off
    }

    var isQueueLoading: Bool = false

    @ObservationIgnored var queueLoadGeneration = 0

    private(set) var repeatMode: RepeatMode = .off

    private var queueStorage: [QueueEntry] = []

    var suppressNextEmptyQueuePersistence = false

    var preservesSavedSessionWhileDisabled = false

    var restoredPlaybackSessionOwnerScope: String?

    var hasResolvedStartupPlaybackOwnership = false

    var shouldPreserveRestoredPlaybackOwnership: Bool {
        self.isPendingRestoredLoadDeferred && !self.hasResolvedStartupPlaybackOwnership
    }

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

    var currentIndex: Int = 0 {
        didSet {
            self.synchronizeCurrentQueueEntryID()
        }
    }

    private(set) var currentQueueEntryID: UUID?

    var activePlaybackQueueEntryID: UUID?

    var queuePlaybackContext: QueuePlaybackContext {
        QueuePlaybackContext(
            entryID: self.currentQueueEntryID,
            index: self.currentIndex,
            requestGeneration: self.playbackContextGeneration,
            navigationGeneration: self.playbackNavigationGeneration
        )
    }

    var playbackNavigationContext: PlaybackNavigationContext {
        PlaybackNavigationContext(
            requestGeneration: self.playbackContextGeneration,
            navigationGeneration: self.playbackNavigationGeneration
        )
    }

    var showMiniPlayer: Bool = false

    var isMiniPlayerVisible: Bool = false

    var isMiniPlayerMiniaturized: Bool = false

    var shouldHostPlaybackInMiniPlayer: Bool {
        self.isMiniPlayerVisible && !self.isMiniPlayerMiniaturized && !self.showVideo
    }

    var miniPlayerMode: MiniPlayerMode = .auxiliary

    var miniPlayerPanel: MiniPlayerPanel = .compact

    var shouldRestoreMainWindowWhenMiniPlayerCloses: Bool = false

    var miniPlayerMainWindowRestoreRequest: Bool = false

    var pendingPlayVideoId: String?

    var pendingNativeQueueAdvance: PendingNativeQueueAdvance?

    var pendingNativeQueueAdvanceGeneration: Int = 0
    var nativeQueueMaintenanceGeneration: Int = 0
    var nativeQueueMaintenanceTask: Task<Void, Never>?
    @ObservationIgnored var nativeQueueMaintenanceWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    var pendingNativeQueueAdvanceVideoId: String? {
        self.pendingNativeQueueAdvance?.targetVideoId
    }

    private(set) var hasUserInteractedThisSession: Bool = false

    var pendingRestoredSeek: TimeInterval?

    var isPendingRestoredLoadDeferred: Bool = false

    var shouldForcePendingRestoredLoad: Bool = false

    var isRestoringPlaybackSession: Bool = false

    var shouldAutoResumeAfterRestoredLoad: Bool = false

    var isRestoringExplicitTransportSeek = false

    var shouldFinishRestoredSeekAtEnd = false

    var restoredPlaybackSessionGeneration: Int = 0

    var isAwaitingWebRestoredTrack: Bool = false

    var hasIssuedAutoplayPauseDuringDeferredRestore: Bool = false

    var currentTrackLikeStatus: LikeStatus = .indifferent

    @ObservationIgnored var currentTrackWebViewLikeStatusEvidence: (videoId: String, status: LikeStatus)?

    var currentTrackInLibrary: Bool = false

    var currentTrackFeedbackTokens: FeedbackTokens?

    var showLyrics: Bool = false {
        didSet {
            if self.showLyrics, self.showQueue {
                self.showQueue = false
            }
        }
    }

    var showFullScreenPlayer: Bool = false

    private(set) var artistNavigationRequest: UUID?

    func requestArtistNavigation() {
        self.artistNavigationRequest = UUID()
    }

    func consumeArtistNavigationRequest(_ request: UUID) -> Bool {
        guard self.artistNavigationRequest == request else { return false }
        self.artistNavigationRequest = nil
        return true
    }

    var queueDisplayMode: QueueDisplayMode = .popup

    var showQueue: Bool = false {
        didSet {
            if self.showQueue, self.showLyrics {
                self.showLyrics = false
            }
        }
    }

    var currentTrackHasVideo: Bool = false

    var showVideo: Bool = false

    var isAirPlayConnected: Bool = false

    let logger = DiagnosticsLogger.player
    var ytMusicClient: (any YTMusicClientProtocol)?
    var authService: AuthService?
    var songLikeStatusManager = SongLikeStatusManager.shared

    private(set) var nowPlayingTracklistProvider: NowPlayingTracklistProvider?

    var mixContinuationToken: String?
    var mixContinuationRequiresAuth = false
    var playbackContextGeneration = 0
    var pendingPlaybackSelectionGeneration = 0
    var playbackNavigationGeneration = 0
    var queueMutationGeneration = 0
    var automaticQueueMutationCount = 0
    var startRadioRefreshGeneration = 0
    var explicitPauseGeneration = 0
    var musicPlaybackIntentGeneration: UInt64 = 0
    var musicPlaybackReservationGeneration: UInt64 = 0
    var musicPlaybackIntentIssuedAtMilliseconds: Double = 0
    var musicPlaybackIntentAcceptsPriorTerminalEvent = false
    var musicPlaybackMinimumAcceptedTerminalIntentGeneration: UInt64 = 0
    var libraryMutationStates: [String: MusicLibraryMutationState] = [:]
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

    var isFetchingMoreMixSongs: Bool = false
    var activeMixContinuationRequestID: UUID?

    @ObservationIgnored var mixContinuationFetchWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored var mixContinuationCompletionGeneration: UInt64 = 0

    var smartShuffleSeenSuggestionIds: Set<String> = []

    var smartShuffleExhaustedSeeds: Set<String> = []

    var isApplyingSmartShuffle: Bool = false

    @ObservationIgnored var smartShuffleFillTask: Task<Void, Never>?

    @ObservationIgnored var smartShuffleFillEpoch = 0

    static let queueDisplayModeKey = "kaset.queue.displayMode"

    var queueUndoHistory: [QueueState] = []
    var queueRedoHistory: [QueueState] = []
    static let queueUndoMaxCount = 10

    private var forwardSkipIndexStack: [Int] = []

    var queueOrderBeforeShuffle: [QueueEntry]?

    static let volumeKey = "playerVolume"
    static let volumeBeforeMuteKey = "playerVolumeBeforeMute"
    static let shuffleEnabledKey = "playerShuffleEnabled"
    static let shuffleModeKey = "playerShuffleMode"
    static let repeatModeKey = "playerRepeatMode"

    @ObservationIgnored var lastSavedPlaybackSessionSignature: Data?

    @ObservationIgnored var queuePersistenceWriteCountForTesting = 0

    @ObservationIgnored var queuePersistenceKeySuffix = ""

    @ObservationIgnored var enrichmentTask: Task<Void, Never>?

    @ObservationIgnored var queueEnrichmentInitialDelay: Duration = .seconds(2)

    @ObservationIgnored var queueEnrichmentRetryDelay: Duration = .seconds(30)

    static let maxQueueEnrichmentAttempts = 3

    @ObservationIgnored var queueEnrichmentAttemptsByEntryID: [UUID: Int] = [:]

    @ObservationIgnored var queueEnrichmentGeneration = 0

    @ObservationIgnored var isQueueEnrichmentRunning = false

    @ObservationIgnored var queueEnrichmentRunningGeneration: Int?

    @ObservationIgnored var queueEnrichmentNeedsReschedule = false

    @ObservationIgnored var isApplyingQueueEnrichmentResult = false

    override init() {
        super.init()
        self.observeNowPlayingLikeStatus()
        if UserDefaults.standard.object(forKey: Self.volumeKey) != nil {
            let savedVolume = UserDefaults.standard.double(forKey: Self.volumeKey)
            self.volume = max(0, min(1, savedVolume))
            self.logger.info("Restored saved volume: \(self.volume)")
        }
        if UserDefaults.standard.object(forKey: Self.volumeBeforeMuteKey) != nil {
            let savedVolumeBeforeMute = UserDefaults.standard.double(forKey: Self.volumeBeforeMuteKey)
            self.volumeBeforeMute = savedVolumeBeforeMute > 0 ? savedVolumeBeforeMute : 1.0
            self.logger.info("Restored volumeBeforeMute: \(self.volumeBeforeMute)")
        } else {
            self.volumeBeforeMute = self.volume > 0 ? self.volume : 1.0
        }

        if SettingsManager.shared.rememberPlaybackSettings {
            if let savedMode = UserDefaults.standard.string(forKey: Self.shuffleModeKey),
               let mode = ShuffleMode(rawValue: savedMode)
            {
                self.shuffleMode = mode
                self.logger.info("Restored shuffle mode: \(self.shuffleMode.rawValue)")
            } else if UserDefaults.standard.object(forKey: Self.shuffleEnabledKey) != nil {
                self.shuffleMode = UserDefaults.standard.bool(forKey: Self.shuffleEnabledKey) ? .on : .off
                self.logger.info("Migrated legacy shuffle state to mode: \(self.shuffleMode.rawValue)")
            }

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

        if let savedMode = UserDefaults.standard.string(forKey: Self.queueDisplayModeKey),
           let mode = QueueDisplayMode(rawValue: savedMode)
        {
            self.queueDisplayMode = mode
            self.logger.info("Restored queue display mode: \(mode.displayName)")
        }

        self.loadMockStateIfNeeded()

        self.startQueueEnrichmentService()
    }

    func rememberVolumeBeforeMute(_ value: Double) {
        let normalizedValue = value > 0 ? value : 1.0
        self.volumeBeforeMute = normalizedValue
        UserDefaults.standard.set(normalizedValue, forKey: Self.volumeBeforeMuteKey)
    }

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

    func markUserInteractedThisSession() {
        self.hasUserInteractedThisSession = true
    }

    func clearForwardSkipNavigationStack() {
        self.forwardSkipIndexStack.removeAll()
    }

    func setQueue(_ songs: [Song], entryIDs: [UUID]? = nil) {
        let entries = zip(entryIDs ?? songs.map { _ in UUID() }, songs).map { QueueEntry(id: $0.0, song: $0.1) }
        self.setQueue(entries: entries.count == songs.count ? entries : songs.map { QueueEntry(id: UUID(), song: $0) })
    }

    func setQueue(entries: [QueueEntry]) {
        let queueStructureChanged = self.queueStorage.count != entries.count
            || zip(self.queueStorage, entries).contains { existing, replacement in
                existing.id != replacement.id
                    || existing.song.videoId != replacement.song.videoId
                    || existing.source != replacement.source
            }
        if queueStructureChanged {
            self.queueMutationGeneration &+= 1
        }
        if queueStructureChanged,
           !NativeQueueMaintenanceContext.isApplyingQueueMutation,
           !self.isApplyingQueueEnrichmentResult
        {
            self.clearNativeQueueMaintenance()
        }
        let pendingGeneration = self.pendingNativeQueueAdvance?.generation
        self.queueStorage = entries
        if let activePlaybackQueueEntryID,
           !entries.contains(where: { $0.id == activePlaybackQueueEntryID })
        {
            self.activePlaybackQueueEntryID = nil
        }
        self.synchronizeCurrentQueueEntryID()
        if NativeQueueMaintenanceContext.isApplyingQueueMutation {
            self.resumeNativeQueueMaintenanceWaitersIfSuccessorMaterialized()
        }
        self.queueDidChangeForEnrichment()

        if let pendingGeneration,
           !self.isPendingNativeQueueAdvanceValid
        {
            Task {
                await self.fallbackInvalidatedNativeQueueAdvance(
                    generation: pendingGeneration,
                    reason: "queue adjacency changed"
                )
            }
        }
    }

    func synchronizeCurrentQueueEntryID() {
        self.currentQueueEntryID = self.queueStorage[safe: self.currentIndex]?.id
    }

    func clearWebQueueInjectionState() {
        self.webQueueInjectionGeneration &+= 1
        SingletonPlayerWebView.shared.cancelQueueInjection()
        self.injectedWebQueueVideoId = nil
        self.pendingWebQueueInjectionVideoId = nil
        self.webQueueInjectionRetries = nil
    }

    func pushForwardSkipStackIfLeavingIndex(for newIndex: Int) {
        let from = self.currentIndex
        guard from != newIndex else { return }
        self.forwardSkipIndexStack.append(from)
    }

    func popForwardSkipIndex() -> Int? {
        self.forwardSkipIndexStack.popLast()
    }

    func peekForwardSkipIndex() -> Int? {
        self.forwardSkipIndexStack.last
    }

    private func loadMockStateIfNeeded() {
        guard UITestConfig.isUITestMode else { return }

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

        if let isPlayingString = UITestConfig.environmentValue(for: UITestConfig.mockIsPlayingKey) {
            let isPlaying = isPlayingString == "true"
            self.state = isPlaying ? .playing : .paused
            self.logger.debug("Loaded mock playing state: \(isPlaying)")
        }

        if let hasVideoString = UITestConfig.environmentValue(for: UITestConfig.mockHasVideoKey) {
            let hasVideo = hasVideoString == "true"
            self.currentTrackHasVideo = hasVideo
            self.logger.debug("Loaded mock video availability: \(hasVideo)")
        }
    }

    func setSongLikeStatusManager(_ manager: SongLikeStatusManager) {
        self.songLikeStatusManager = manager
    }

    func setYTMusicClient(_ client: any YTMusicClientProtocol) {
        self.ytMusicClient = client
        self.resetQueueEnrichmentAttemptState()
        self.scheduleQueueEnrichmentIfNeeded()
    }

    func setAuthService(_ authService: AuthService) {
        self.authService = authService
    }

    func setNowPlayingTracklistProvider(_ provider: NowPlayingTracklistProvider) {
        self.nowPlayingTracklistProvider = provider
        self.driveNowPlayingTracklistProvider()
    }

    var canPerformAccountMutation: Bool {
        self.authService?.hasPersonalAccount ?? false
    }

    var songNearingEnd: Bool = false

    var isKasetInitiatedPlayback: Bool = false

    var shouldSuppressAutoplayAfterQueueEnd: Bool = false

    var injectedWebQueueVideoId: String?

    var pendingWebQueueInjectionVideoId: String?

    var webQueueInjectionGeneration: Int = 0

    @ObservationIgnored var webQueueInjectionRetries: (pair: (videoId: String, sourceVideoId: String?), remaining: Int)?

    var protectedQueueNavigationVideoId: String?

    var protectedQueueNavigationConfirmedAt: ContinuousClock.Instant?

    var protectedQueueNavigationStartedAt: ContinuousClock.Instant?

    var queueNavigationRecoveryGeneration: Int = 0
    var queueNavigationRecoveryVideoId: String?
    var queueNavigationRecoveryLoadTask: Task<Void, Never>?
    var queueNavigationRecoveryTask: Task<Void, Never>?

    var videoWindowOpenedAt: ContinuousClock.Instant?

    var lastRepeatOneRecoveryInstant: ContinuousClock.Instant?

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
