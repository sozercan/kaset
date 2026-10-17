import AppKit
import Foundation
import MediaPlayer
import Observation
import os

// MARK: - RemoteMusicCommandDirection

enum RemoteMusicCommandDirection: Equatable {
    case forward
    case backward
}

// MARK: - RemoteMusicCommandPayload

enum RemoteMusicCommandPayload: Equatable {
    case play
    case pause
    case togglePlayPause
    case nextPrevious(direction: RemoteMusicCommandDirection)
    case skip(interval: TimeInterval, direction: RemoteMusicCommandDirection)
    case absoluteSeek(position: TimeInterval)
}

// MARK: - CapturedRemoteMusicCommand

struct CapturedRemoteMusicCommand: Equatable {
    let sequence: UInt64
    let issuedAtMilliseconds: Double
    let admittedAt: ContinuousClock.Instant
    let payload: RemoteMusicCommandPayload
}

// MARK: - RemoteMusicCommandIngress

/// Thread-safe callback inbox for native media commands. Callback order and clocks
/// are captured synchronously before any MainActor scheduling can reorder delivery.
final class RemoteMusicCommandIngress: @unchecked Sendable {
    private struct State {
        var nextSequence: UInt64 = 0
        var pendingCommands: [CapturedRemoteMusicCommand] = []
        var isDrainScheduled = false
    }

    private let lock = NSLock()
    private var state = State()

    /// Returns `true` only when the caller must schedule the single MainActor drain.
    @discardableResult
    func capture(_ payload: RemoteMusicCommandPayload) -> Bool {
        self.lock.withLock {
            self.captureLocked(
                payload,
                issuedAtMilliseconds: Date().timeIntervalSince1970 * 1000,
                admittedAt: ContinuousClock.now
            )
        }
    }

    /// Deterministic clock injection for ingress ordering and stale-admission tests.
    @discardableResult
    func capture(
        _ payload: RemoteMusicCommandPayload,
        issuedAtMilliseconds: Double,
        admittedAt: ContinuousClock.Instant
    ) -> Bool {
        self.lock.withLock {
            self.captureLocked(
                payload,
                issuedAtMilliseconds: issuedAtMilliseconds,
                admittedAt: admittedAt
            )
        }
    }

    func takePendingCommands() -> [CapturedRemoteMusicCommand] {
        self.lock.withLock {
            let commands = self.state.pendingCommands
            self.state.pendingCommands.removeAll(keepingCapacity: true)
            return commands
        }
    }

    /// Returns `true` when callbacks arrived during the last batch and the existing
    /// drain must loop. Otherwise, it atomically rearms scheduling for the next callback.
    func finishDrainBatch() -> Bool {
        self.lock.withLock {
            guard self.state.pendingCommands.isEmpty else { return true }
            self.state.isDrainScheduled = false
            return false
        }
    }

    private func captureLocked(
        _ payload: RemoteMusicCommandPayload,
        issuedAtMilliseconds: Double,
        admittedAt: ContinuousClock.Instant
    ) -> Bool {
        let command = CapturedRemoteMusicCommand(
            sequence: self.state.nextSequence,
            issuedAtMilliseconds: issuedAtMilliseconds,
            admittedAt: admittedAt,
            payload: payload
        )
        self.state.nextSequence &+= 1
        self.state.pendingCommands.append(command)

        guard !self.state.isDrainScheduled else { return false }
        self.state.isDrainScheduled = true
        return true
    }
}

// MARK: - NowPlayingInfoPublishing

/// The slice of `MPNowPlayingInfoCenter` the native claim writes, so claim transitions can be
/// tested without publishing to the system Now Playing center.
@MainActor
protocol NowPlayingInfoPublishing: AnyObject {
    var nowPlayingInfo: [String: Any]? { get set }
    var playbackState: MPNowPlayingPlaybackState { get set }
}

// MARK: - MPNowPlayingInfoCenter + NowPlayingInfoPublishing

extension MPNowPlayingInfoCenter: NowPlayingInfoPublishing {}

// MARK: - NowPlayingManager

/// Manages remote-command routing and the app's Now Playing ownership.
/// WebKit publishes the rich card for the music page as its own Now Playing entry, so for music
/// Kaset publishes only its playback state: its own player stays a media-key target, and the card
/// is the single Kaset entry in Control Center. YouTube video keeps a tagged minimal entry.
@MainActor
@Observable
final class NowPlayingManager {
    /// Shared singleton instance. Must be configured with `configure(playerService:)` before use.
    static let shared = NowPlayingManager()

    private var playerService: PlayerService?
    private let logger = DiagnosticsLogger.player
    private var isConfigured = false
    /// What Kaset is publishing to the system center. The claim's tag lets release logic
    /// distinguish our metadata from anything else.
    private var nativeOwnership: NativeNowPlayingOwnership = .none
    @ObservationIgnored private var nowPlayingObservationGeneration: UInt64 = 0

    /// YouTube video routing (optional; absent in music-only flows).
    /// When the arbiter says the video source played last, play/pause/toggle
    /// media keys control it instead of the music player. Guarded so music
    /// behavior is identical when video routing is not configured/active.
    private weak var youtubePlayerService: YouTubePlayerService?
    private weak var playbackArbiter: PlaybackArbiter?
    private let settings = SettingsManager.shared
    private let remoteMusicCommandIngress = RemoteMusicCommandIngress()
    private static let defaultSkipInterval: TimeInterval = 15
    nonisolated static let nativeClaimServiceIdentifier = "com.sertacozercan.Kaset.native-now-playing-claim"

    private init() {}

    // MARK: - Now Playing Claim

    enum NativeClaimPlaybackState: Equatable, Sendable {
        case playing
        case paused

        var mediaPlayerPlaybackState: MPNowPlayingPlaybackState {
            switch self {
            case .playing: .playing
            case .paused: .paused
            }
        }
    }

    /// What Kaset should tell the system Now Playing center for the current player state.
    /// `handsOff` keeps an existing claim (marked playing) without publishing a new one,
    /// `stateOnly` publishes playback state without metadata next to WebKit's music card, and
    /// `release` clears what Kaset published when no resumable media remains.
    enum NowPlayingClaim: Equatable {
        case handsOff
        case stateOnly(NativeClaimPlaybackState)
        case release
        case claim(title: String, artist: String, playbackState: NativeClaimPlaybackState)
    }

    /// What Kaset currently publishes to the system Now Playing center.
    enum NativeNowPlayingOwnership: Equatable {
        case none
        /// Playback state only: keeps Kaset's own player a media-key target without adding a
        /// second Control Center entry next to WebKit's card.
        case stateOnly
        /// Tagged minimal metadata for a YouTube video (title and channel).
        case claim
    }

    struct ActiveVideoClaim: Equatable, Sendable {
        let title: String
        let artist: String
        let playbackState: NativeClaimPlaybackState
        let isPlaybackConfirmed: Bool
    }

    /// Pure decision: given the active source and its playback state, what claim do we want?
    /// Music publishes playback state only: WebKit's card for the music page is in Control Center
    /// as soon as the page loads a track, so metadata of our own would be a second entry (#457).
    /// The state keeps Kaset's own player a media-key target while paused. A loading track keeps
    /// an existing claim without publishing a new one. A paused or loading video keeps a minimal
    /// video claim until WebKit reports playback.
    nonisolated static func desiredClaim(
        state: PlayerService.PlaybackState,
        hasTrack: Bool,
        activeVideo: ActiveVideoClaim?
    ) -> NowPlayingClaim {
        if let activeVideo {
            guard activeVideo.isPlaybackConfirmed else {
                return .claim(
                    title: activeVideo.title,
                    artist: activeVideo.artist,
                    playbackState: activeVideo.playbackState
                )
            }
            return .handsOff
        }

        switch state {
        case .playing:
            return .stateOnly(.playing)
        case .buffering, .loading:
            return .handsOff
        case .idle, .paused, .ended, .error:
            return hasTrack ? .stateOnly(.paused) : .release
        }
    }

    /// Reads current player state and pushes the desired claim to the system center.
    private func updateNowPlayingClaim() {
        guard let player = self.playerService else { return }
        let claim = Self.desiredClaim(
            state: player.state,
            hasTrack: player.currentTrack != nil,
            activeVideo: self.activeVideoClaimInput
        )
        self.applyNowPlayingClaim(claim)
    }

    /// Maps a claim onto `MPNowPlayingInfoCenter`.
    private func applyNowPlayingClaim(_ claim: NowPlayingClaim) {
        self.nativeOwnership = Self.apply(
            claim,
            to: MPNowPlayingInfoCenter.default(),
            ownership: self.nativeOwnership
        )
    }

    /// Applies `claim` to `center` and returns what Kaset publishes afterwards.
    /// Metadata is only ever cleared when it carries Kaset's tag.
    static func apply(
        _ claim: NowPlayingClaim,
        to center: any NowPlayingInfoPublishing,
        ownership: NativeNowPlayingOwnership
    ) -> NativeNowPlayingOwnership {
        switch claim {
        case .handsOff:
            switch ownership {
            case .none:
                return .none
            case .stateOnly:
                center.playbackState = .playing
                return .stateOnly
            case .claim:
                guard self.isNativeClaim(center.nowPlayingInfo) else { return .none }
                // Keep the existing fallback, marked as playing, without publishing a new one.
                center.playbackState = .playing
                return .claim
            }
        case let .stateOnly(playbackState):
            // WebKit publishes its card as a separate Now Playing entry rather than replacing the
            // app's metadata, so metadata of ours would show up as a second Kaset entry (#457).
            if self.isNativeClaim(center.nowPlayingInfo) {
                center.nowPlayingInfo = nil
            }
            center.playbackState = playbackState.mediaPlayerPlaybackState
            return .stateOnly
        case .release:
            switch ownership {
            case .none:
                return .none
            case .stateOnly:
                center.playbackState = .stopped
                return .none
            case .claim:
                guard self.isNativeClaim(center.nowPlayingInfo) else { return .none }
                center.playbackState = .stopped
                center.nowPlayingInfo = nil
                return .none
            }
        case let .claim(title, artist, playbackState):
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: title,
                MPNowPlayingInfoPropertyServiceIdentifier: Self.nativeClaimServiceIdentifier,
            ]
            if !artist.isEmpty {
                info[MPMediaItemPropertyArtist] = artist
            }
            center.nowPlayingInfo = info
            center.playbackState = playbackState.mediaPlayerPlaybackState
            return .claim
        }
    }

    /// Returns whether the current center metadata is the tagged native claim Kaset published.
    nonisolated static func isNativeClaim(_ info: [String: Any]?) -> Bool {
        info?[MPNowPlayingInfoPropertyServiceIdentifier] as? String == self.nativeClaimServiceIdentifier
    }

    /// Video metadata used for a native fallback until its WebView confirms active playback.
    private var activeVideoClaimInput: ActiveVideoClaim? {
        guard self.routesToYouTubeVideo,
              let youtube = self.youtubePlayerService,
              let video = youtube.currentVideo
        else { return nil }

        return ActiveVideoClaim(
            title: video.title,
            artist: video.channelName ?? "",
            playbackState: youtube.isPlaying || youtube.isPlaybackLoading ? .playing : .paused,
            isPlaybackConfirmed: youtube.isPlaying && !youtube.isPlaybackLoading
        )
    }

    /// Replaces the current one-shot observation loop with one that tracks the latest dependencies.
    private func restartNowPlayingObservation() {
        self.nowPlayingObservationGeneration &+= 1
        self.observePlaybackState(generation: self.nowPlayingObservationGeneration)
    }

    /// Re-runs the claim whenever music state, the current track, or active-video state changes.
    private func observePlaybackState(generation: UInt64) {
        withObservationTracking {
            _ = self.playerService?.state
            _ = self.playerService?.currentTrack
            _ = self.activeVideoClaimInput
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.nowPlayingObservationGeneration == generation
                else { return }

                self.updateNowPlayingClaim()
                self.observePlaybackState(generation: generation)
            }
        }
    }

    /// Configures the singleton with a player service. Only configures once; subsequent calls are ignored.
    func configure(playerService: PlayerService) {
        guard !self.isConfigured else {
            self.logger.debug("NowPlayingManager already configured, skipping")
            return
        }
        self.isConfigured = true
        self.playerService = playerService
        self.setupRemoteCommands()
        self.syncMediaControlSetting()
        self.syncPlaybackAudioQualitySetting()
        self.logger.info("NowPlayingManager configured")

        self.observeSettingsChanges()

        self.updateNowPlayingClaim()
        self.restartNowPlayingObservation()
    }

    /// Registers the YouTube video player for media-key routing.
    /// Additive: without this call (or when video is inactive), all commands
    /// route to the music player exactly as before.
    func configureYouTubeRouting(
        youtubePlayerService: YouTubePlayerService,
        arbiter: PlaybackArbiter
    ) {
        self.youtubePlayerService = youtubePlayerService
        self.playbackArbiter = arbiter
        self.restartNowPlayingObservation()
        self.updateNowPlayingClaim()
        self.logger.info("NowPlayingManager: YouTube video routing configured")
    }

    /// Whether play/pause media keys should control the YouTube video player.
    private var routesToYouTubeVideo: Bool {
        self.playbackArbiter?.routesMediaKeysToVideo == true
    }

    nonisolated static func routesAbsoluteSeekToVideo(
        routesToYouTubeVideo: Bool,
        hasYouTubePlayer: Bool
    ) -> Bool {
        routesToYouTubeVideo && hasYouTubePlayer
    }

    private func observeSettingsChanges() {
        withObservationTracking {
            _ = self.settings.mediaControlStyle
            _ = self.settings.playbackAudioQuality
        } onChange: {
            Task { @MainActor [weak self] in
                self?.syncMediaControlSetting()
                self?.syncPlaybackAudioQualitySetting()
                self?.observeSettingsChanges()
            }
        }
    }

    /// Syncs the media control style setting to the singleton WebView and its bootstrap state.
    private func syncMediaControlSetting() {
        let useNextPrev = self.settings.mediaControlStyle == .nextPreviousTrack
        SingletonPlayerWebView.shared.setMediaControlStyle(useNextPrev: useNextPrev)
        self.syncSkipCommandAvailability(useNextPrev: useNextPrev)
    }

    private func syncSkipCommandAvailability(useNextPrev: Bool) {
        let commandCenter = MPRemoteCommandCenter.shared()
        let enableSkipCommands = !useNextPrev
        commandCenter.skipForwardCommand.isEnabled = enableSkipCommands
        commandCenter.skipBackwardCommand.isEnabled = enableSkipCommands
    }

    /// Syncs the preferred playback audio quality setting to the singleton WebView and its bootstrap state.
    private func syncPlaybackAudioQualitySetting() {
        SingletonPlayerWebView.shared.setPlaybackAudioQuality(self.settings.playbackAudioQuality)
    }

    // MARK: - Remote Commands

    private func setupRemoteCommands() {
        guard self.playerService != nil else { return }
        let commandCenter = MPRemoteCommandCenter.shared()
        let ingress = self.remoteMusicCommandIngress
        let captureCommand: @Sendable (RemoteMusicCommandPayload) -> Void = { [weak self] payload in
            guard ingress.capture(payload) else { return }
            Task { @MainActor [weak self] in
                self?.drainRemoteMusicCommandIngress()
            }
        }

        // Remove any existing targets to prevent duplicates
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)

        // Play command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { _ in
            captureCommand(.play)
            return .success
        }

        // Pause command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { _ in
            captureCommand(.pause)
            return .success
        }

        // Toggle play/pause command
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { _ in
            captureCommand(.togglePlayPause)
            return .success
        }

        // Next track command
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { _ in
            captureCommand(.nextPrevious(direction: .forward))
            return .success
        }

        // Previous track command
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { _ in
            captureCommand(.nextPrevious(direction: .backward))
            return .success
        }

        // Skip forward command (Control Center skip buttons or media keys)
        commandCenter.skipForwardCommand.isEnabled = self.settings.mediaControlStyle == .skipForwardBackward
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.defaultSkipInterval)]
        commandCenter.skipForwardCommand.addTarget { event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.defaultSkipInterval
            captureCommand(.skip(interval: interval, direction: .forward))
            return .success
        }

        // Skip backward command (Control Center skip buttons or media keys)
        commandCenter.skipBackwardCommand.isEnabled = self.settings.mediaControlStyle == .skipForwardBackward
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.defaultSkipInterval)]
        commandCenter.skipBackwardCommand.addTarget { event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.defaultSkipInterval
            captureCommand(.skip(interval: interval, direction: .backward))
            return .success
        }

        // Change playback position command
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            captureCommand(.absoluteSeek(position: positionEvent.positionTime))
            return .success
        }

        self.logger.info("Remote commands configured")
    }

    private func drainRemoteMusicCommandIngress() {
        while true {
            let commands = self.remoteMusicCommandIngress.takePendingCommands()
            if let player = self.playerService {
                for command in commands {
                    self.handleCapturedRemoteMusicCommand(command, player: player)
                }
            }
            guard self.remoteMusicCommandIngress.finishDrainBatch() else { return }
        }
    }

    private func handleCapturedRemoteMusicCommand(
        _ capturedCommand: CapturedRemoteMusicCommand,
        player: PlayerService
    ) {
        switch capturedCommand.payload {
        case .play:
            if self.routesToYouTubeVideo, let youtube = self.youtubePlayerService {
                youtube.handleRemoteResume(
                    issuedAtMilliseconds: capturedCommand.issuedAtMilliseconds
                )
            } else {
                self.enqueueMusicRemoteCommand(.play, capturedCommand: capturedCommand, player: player)
            }
        case .pause:
            if self.routesToYouTubeVideo, let youtube = self.youtubePlayerService {
                youtube.handleRemotePause(
                    issuedAtMilliseconds: capturedCommand.issuedAtMilliseconds
                )
            } else {
                self.enqueueMusicRemoteCommand(.pause, capturedCommand: capturedCommand, player: player)
            }
        case .togglePlayPause:
            if self.routesToYouTubeVideo, let youtube = self.youtubePlayerService {
                youtube.handleRemoteTogglePlayPause(
                    issuedAtMilliseconds: capturedCommand.issuedAtMilliseconds
                )
            } else {
                self.enqueueMusicRemoteCommand(.togglePlayPause, capturedCommand: capturedCommand, player: player)
            }
        case let .nextPrevious(direction):
            self.handleNextPreviousMediaKey(
                direction: direction,
                capturedCommand: capturedCommand,
                player: player
            )
        case let .skip(interval, direction):
            if self.routesToYouTubeVideo, let youtube = self.youtubePlayerService {
                guard interval.isFinite else { return }
                let delta = direction == .forward ? interval : -interval
                youtube.handleRemoteSeek(
                    to: max(0, youtube.progress + delta),
                    issuedAtMilliseconds: capturedCommand.issuedAtMilliseconds
                )
                return
            }
            self.handleSkipCommand(
                interval: interval,
                direction: direction,
                capturedCommand: capturedCommand,
                player: player
            )
        case let .absoluteSeek(position):
            guard position.isFinite else { return }
            if Self.routesAbsoluteSeekToVideo(
                routesToYouTubeVideo: self.routesToYouTubeVideo,
                hasYouTubePlayer: self.youtubePlayerService != nil
            ), let youtube = self.youtubePlayerService {
                youtube.handleRemoteSeek(
                    to: position,
                    issuedAtMilliseconds: capturedCommand.issuedAtMilliseconds
                )
            } else {
                self.enqueueMusicRemoteCommand(
                    .absoluteSeek(position: position),
                    capturedCommand: capturedCommand,
                    player: player
                )
            }
        }
    }

    private func handleNextPreviousMediaKey(
        direction: RemoteMusicCommandDirection,
        capturedCommand: CapturedRemoteMusicCommand,
        player: PlayerService
    ) {
        if self.routesToYouTubeVideo, let youtube = self.youtubePlayerService {
            if self.settings.mediaControlStyle == .skipForwardBackward {
                let delta = direction == .forward ? Self.defaultSkipInterval : -Self.defaultSkipInterval
                youtube.handleRemoteSeek(
                    to: max(0, youtube.progress + delta),
                    issuedAtMilliseconds: capturedCommand.issuedAtMilliseconds
                )
            } else if direction == .forward {
                Task { @MainActor in
                    await youtube.handleRemoteSkipForward(
                        issuedAtMilliseconds: capturedCommand.issuedAtMilliseconds
                    )
                }
            } else {
                youtube.handleRemoteSkipBackward(
                    issuedAtMilliseconds: capturedCommand.issuedAtMilliseconds
                )
            }
            return
        }

        if self.settings.mediaControlStyle == .skipForwardBackward {
            self.handleSkipCommand(
                interval: Self.defaultSkipInterval,
                direction: direction,
                capturedCommand: capturedCommand,
                player: player
            )
        } else {
            self.handleTrackNavigation(
                direction: direction,
                capturedCommand: capturedCommand,
                player: player
            )
        }
    }

    private func handleSkipCommand(
        interval: TimeInterval,
        direction: RemoteMusicCommandDirection,
        capturedCommand: CapturedRemoteMusicCommand,
        player: PlayerService
    ) {
        guard interval.isFinite,
              player.currentTrack != nil || player.pendingPlayVideoId != nil || !player.queue.isEmpty
        else { return }

        if self.settings.mediaControlStyle == .nextPreviousTrack {
            self.handleTrackNavigation(
                direction: direction,
                capturedCommand: capturedCommand,
                player: player
            )
            return
        }

        let delta = direction == .forward ? interval : -interval
        self.enqueueMusicRemoteCommand(
            .relativeSeek(delta: delta, admittedAt: capturedCommand.admittedAt),
            capturedCommand: capturedCommand,
            player: player
        )
    }

    private func handleTrackNavigation(
        direction: RemoteMusicCommandDirection,
        capturedCommand: CapturedRemoteMusicCommand,
        player: PlayerService
    ) {
        self.enqueueMusicRemoteCommand(
            direction == .forward ? .next : .previous,
            capturedCommand: capturedCommand,
            player: player
        )
    }

    private func enqueueMusicRemoteCommand(
        _ command: MusicRemoteTransportCommand,
        capturedCommand: CapturedRemoteMusicCommand,
        player: PlayerService
    ) {
        player.enqueueRemoteMusicTransportCommand(
            command,
            issuedAtMilliseconds: capturedCommand.issuedAtMilliseconds
        )
    }
}
