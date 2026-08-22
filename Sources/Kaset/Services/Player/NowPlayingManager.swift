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

// MARK: - NowPlayingInfoCenter

/// The slice of `MPNowPlayingInfoCenter` the claim logic writes, so withdrawal can be tested
/// without a live system center.
@MainActor
protocol NowPlayingInfoCenter: AnyObject {
    var nowPlayingInfo: [String: Any]? { get set }
    var playbackState: MPNowPlayingPlaybackState { get set }
}

// MARK: - MPNowPlayingInfoCenter + NowPlayingInfoCenter

extension MPNowPlayingInfoCenter: NowPlayingInfoCenter {}

// MARK: - NowPlayingManager

/// Manages remote-command routing and the app's Now Playing ownership.
/// WebKit publishes the rich card during confirmed playback; Kaset publishes tagged minimal
/// metadata during paused or loading gaps so media keys continue routing to the active source.
@MainActor
@Observable
final class NowPlayingManager {
    /// Shared singleton instance. Must be configured with `configure(playerService:)` before use.
    static let shared = NowPlayingManager()

    private var playerService: PlayerService?
    private let logger = DiagnosticsLogger.player
    private var isConfigured = false
    /// True while Kaset is asserting a tagged native Now Playing claim.
    /// The tag lets release logic distinguish our metadata from a newer WebKit card.
    private var isAssertingNativeClaim = false
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

    @ObservationIgnored private var routeRestoreTask: Task<Void, Never>?
    @ObservationIgnored private var routeRestoreGeneration: UInt64 = 0
    private static let routeRestoreDelays: [Duration] = [
        .milliseconds(500),
        .milliseconds(2000),
    ]

    private init() {}

    // MARK: - Now Playing Claim

    enum NativeClaimPlaybackState: Equatable, Sendable {
        case playing
        case paused
    }

    /// What Kaset should tell the system Now Playing center for the current player state.
    /// Both non-claim cases withdraw Kaset's tagged entry — they differ only in why:
    /// `handsOff` because WebKit's own Now Playing client owns the card during playback,
    /// `release` because no resumable media remains.
    enum NowPlayingClaim: Equatable {
        case handsOff
        case release
        case claim(title: String, artist: String, playbackState: NativeClaimPlaybackState)
    }

    struct ActiveVideoClaim: Equatable, Sendable {
        let title: String
        let artist: String
        let playbackState: NativeClaimPlaybackState
        let isPlaybackConfirmed: Bool
    }

    /// Pure decision: given the active source and its playback state, what claim do we want?
    /// Confirmed playback stays hands-off so WebKit owns the rich Control Center card. A paused or
    /// loading video keeps a minimal video claim until WebKit reports playback, while inactive music
    /// keeps the equivalent music claim so the Play key resumes Kaset instead of Apple Music.
    nonisolated static func desiredClaim(
        state: PlayerService.PlaybackState,
        track: (title: String, artist: String)?,
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
        case .playing, .buffering:
            // `buffering` is a stall inside playback that already started, so WebKit owns
            // its card by now. Claiming here would recreate the competing second entry.
            // Nothing in the music player assigns `buffering` today; if that changes, decide
            // this case by whether playback was ever confirmed rather than by the state name,
            // the way `activeVideo` already does with `isPlaybackConfirmed`.
            return .handsOff
        case .loading:
            // Playback is starting and WebKit has not published its card yet. Withdrawing
            // here would leave the app with no Now Playing entry — and no media keys — for
            // the whole load, so hold a playing-state claim until `.playing` hands over.
            guard let track else { return .release }
            return .claim(title: track.title, artist: track.artist, playbackState: .playing)
        case .idle, .paused, .ended, .error:
            guard let track else { return .release }
            return .claim(title: track.title, artist: track.artist, playbackState: .paused)
        }
    }

    /// Reads current player state and pushes the desired claim to the system center.
    private func updateNowPlayingClaim() {
        guard let player = self.playerService else { return }
        let track = player.currentTrack.map { song in
            (title: song.title, artist: song.artists.map(\.name).joined(separator: ", "))
        }
        let claim = Self.desiredClaim(
            state: player.state,
            track: track,
            activeVideo: self.activeVideoClaimInput
        )
        self.applyNowPlayingClaim(claim)
    }

    /// Maps a claim onto the Now Playing center, withdrawing our entry unless we want one.
    private func applyNowPlayingClaim(_ claim: NowPlayingClaim) {
        self.isAssertingNativeClaim = Self.applyClaim(
            claim,
            isAssertingNativeClaim: self.isAssertingNativeClaim,
            to: MPNowPlayingInfoCenter.default()
        )
    }

    /// Applies `claim` to `center`, returning whether Kaset asserts a native claim afterwards.
    ///
    /// Withdrawing is the interesting half. WebKit registers its own Now Playing client with the
    /// system rather than writing `MPNowPlayingInfoCenter`, so a Kaset claim left in place during
    /// playback does not get replaced — it survives as a second, competing entry for the same
    /// app. Whichever entry was updated most recently owns the media keys, so a stale claim can
    /// silently capture them and answer Play/Pause from a playback state that no longer matches
    /// the page. Clearing here cannot disturb WebKit's card; they are separate clients.
    ///
    /// Only metadata carrying our tag is ever cleared, so a card published by anything else is
    /// left alone.
    @discardableResult
    static func applyClaim(
        _ claim: NowPlayingClaim,
        isAssertingNativeClaim: Bool,
        to center: any NowPlayingInfoCenter
    ) -> Bool {
        switch claim {
        case .handsOff, .release:
            guard isAssertingNativeClaim else { return false }
            guard self.isNativeClaim(center.nowPlayingInfo) else { return false }
            center.playbackState = .stopped
            center.nowPlayingInfo = nil
            return false
        case let .claim(title, artist, playbackState):
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: title,
                MPNowPlayingInfoPropertyServiceIdentifier: Self.nativeClaimServiceIdentifier,
            ]
            if !artist.isEmpty {
                info[MPMediaItemPropertyArtist] = artist
            }
            center.nowPlayingInfo = info
            center.playbackState = switch playbackState {
            case .playing: .playing
            case .paused: .paused
            }
            return true
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

    /// Re-runs the claim whenever music state, track metadata, or active-video state changes.
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
        self.observeOutputDeviceChanges()

        self.updateNowPlayingClaim()
        self.restartNowPlayingObservation()
    }

    // MARK: - Transport Reconciliation

    private func observeOutputDeviceChanges() {
        DefaultOutputDeviceMonitor.shared.start { [weak self] in
            self?.handleOutputDeviceChange()
        }
    }

    /// Runs once the route event has been published, which is the earliest moment a pause that
    /// beat it can be attributed correctly.
    private func handleOutputDeviceChange() {
        self.attributeRouteLossPauseIfPending()
        self.resumeAfterRouteRestoredSoon()
    }

    /// Attributes a pending unattributed pause to a route loss, if one now explains it.
    ///
    /// Safe to call from either side of the race and at any time: it is a no-op without a pending
    /// pause, and the claim is one-shot, so a disconnect still explains at most one pause.
    func attributeRouteLossPauseIfPending() {
        guard let playerService = self.playerService else { return }
        playerService.reattributeRemotePauseToRouteLoss { admittedAt in
            DefaultOutputDeviceMonitor.shared.claimRouteLossPause(
                admittedAt: admittedAt,
                within: Self.routeLossPauseWindow
            )
        }
        guard playerService.routeLossPauseAt != nil else { return }
        self.resumeAfterRouteRestoredSoon()
    }

    /// Resumes playback that a vanished audio route had stopped, once a route is back.
    ///
    /// The device is not immediately usable when the notification lands, and WebKit settles a
    /// route change in stages, so try twice rather than racing it once. Bursts of notifications
    /// collapse into the latest request. `resumeAfterRouteRestored` itself decides whether a
    /// resume is warranted, so both a disconnect and a reconnect can drive this safely.
    func resumeAfterRouteRestoredSoon() {
        self.routeRestoreGeneration &+= 1
        let generation = self.routeRestoreGeneration
        self.routeRestoreTask?.cancel()
        self.routeRestoreTask = Task { @MainActor [weak self] in
            defer {
                if self?.routeRestoreGeneration == generation {
                    self?.routeRestoreTask = nil
                }
            }
            var elapsed = Duration.zero
            for delay in Self.routeRestoreDelays {
                try? await Task.sleep(for: delay - elapsed)
                elapsed = delay
                guard !Task.isCancelled,
                      let self,
                      self.routeRestoreGeneration == generation
                else { return }
                await self.playerService?.resumeAfterRouteRestored()
            }
        }
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
                let command: MusicRemoteTransportCommand = Self.isRouteChangePause(capturedCommand)
                    ? .pauseForRouteChange(admittedAt: capturedCommand.admittedAt)
                    : .pause(admittedAt: capturedCommand.admittedAt)
                self.enqueueMusicRemoteCommand(
                    command,
                    capturedCommand: capturedCommand,
                    player: player
                )
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

    /// Whether the `pause` we just received is the system reacting to a vanished audio route
    /// (unplugged headphones, a Bluetooth device disconnecting) rather than a user request.
    ///
    /// macOS delivers both as the same remote command, so the only thing separating them is
    /// that a route-driven one lands immediately after the output device it was playing to
    /// disappears — measured at 40–60ms. The window absorbs scheduling jitter while staying far
    /// below the time it takes a person to reach for the key, and requiring a *disappearance*
    /// rather than any device change keeps a deliberate pause next to a manual output switch
    /// from being mistaken for one.
    ///
    /// The comparison anchors on when the ingress admitted the command, not on when this drain
    /// runs: the hop to the MainActor is unbounded, and dating the decision to handling time
    /// would let a busy main actor push a real route pause out of the window.
    private static func isRouteChangePause(_ capturedCommand: CapturedRemoteMusicCommand) -> Bool {
        DefaultOutputDeviceMonitor.shared.claimRouteLossPause(
            admittedAt: capturedCommand.admittedAt,
            within: self.routeLossPauseWindow
        )
    }

    /// How closely a `pause` must follow a device disappearing to be attributed to it. Measured
    /// at 40-60ms; generous enough for scheduling jitter, far below human reaction time.
    private static let routeLossPauseWindow = Duration.milliseconds(1500)

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
