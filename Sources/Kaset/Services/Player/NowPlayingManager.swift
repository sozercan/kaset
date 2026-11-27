import AppKit
import Foundation
import MediaPlayer
import Observation
import os

enum RemoteMusicCommandDirection: Equatable {
    case forward
    case backward
}

enum RemoteMusicCommandPayload: Equatable {
    case play
    case pause
    case togglePlayPause
    case nextPrevious(direction: RemoteMusicCommandDirection)
    case trackNavigation(direction: RemoteMusicCommandDirection)
    case skip(interval: TimeInterval, direction: RemoteMusicCommandDirection)
    case absoluteSeek(position: TimeInterval)
}

struct CapturedRemoteMusicCommand: Equatable {
    let sequence: UInt64
    let issuedAtMilliseconds: Double
    let admittedAt: ContinuousClock.Instant
    let payload: RemoteMusicCommandPayload
}

final class RemoteMusicCommandIngress: @unchecked Sendable {
    private struct State {
        var nextSequence: UInt64 = 0
        var pendingCommands: [CapturedRemoteMusicCommand] = []
        var isDrainScheduled = false
    }

    private let lock = NSLock()
    private var state = State()

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

@MainActor
protocol NowPlayingInfoPublishing: AnyObject {
    var nowPlayingInfo: [String: Any]? { get set }
    var playbackState: MPNowPlayingPlaybackState { get set }
}

extension MPNowPlayingInfoCenter: NowPlayingInfoPublishing {}

@MainActor
@Observable
final class NowPlayingManager {
    static let shared = NowPlayingManager()

    private var playerService: PlayerService?
    private let logger = DiagnosticsLogger.player
    private var isConfigured = false
    private var nativeOwnership: NativeNowPlayingOwnership = .none
    @ObservationIgnored private var nowPlayingObservationGeneration: UInt64 = 0

    private weak var youtubePlayerService: YouTubePlayerService?
    private weak var playbackArbiter: PlaybackArbiter?
    private let settings = SettingsManager.shared
    private let remoteMusicCommandIngress = RemoteMusicCommandIngress()
    private static let defaultSkipInterval: TimeInterval = 15
    nonisolated static let nativeClaimServiceIdentifier = "com.sertacozercan.Kaset.native-now-playing-claim"

    private init() {}

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

    enum NowPlayingClaim: Equatable {
        case handsOff
        case stateOnly(NativeClaimPlaybackState)
        case release
        case claim(title: String, artist: String, playbackState: NativeClaimPlaybackState)
    }

    enum NativeNowPlayingOwnership: Equatable {
        case none
        case stateOnly
        case claim
    }

    struct ActiveVideoClaim: Equatable, Sendable {
        let title: String
        let artist: String
        let playbackState: NativeClaimPlaybackState
        let isPlaybackConfirmed: Bool
    }

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

    private func updateNowPlayingClaim() {
        guard let player = self.playerService else { return }
        let claim = Self.desiredClaim(
            state: player.state,
            hasTrack: player.currentTrack != nil,
            activeVideo: self.activeVideoClaimInput
        )
        self.applyNowPlayingClaim(claim)
    }

    private func applyNowPlayingClaim(_ claim: NowPlayingClaim) {
        self.nativeOwnership = Self.apply(
            claim,
            to: MPNowPlayingInfoCenter.default(),
            ownership: self.nativeOwnership
        )
    }

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
                center.playbackState = .playing
                return .claim
            }
        case let .stateOnly(playbackState):
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

    nonisolated static func isNativeClaim(_ info: [String: Any]?) -> Bool {
        info?[MPNowPlayingInfoPropertyServiceIdentifier] as? String == self.nativeClaimServiceIdentifier
    }

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

    private func restartNowPlayingObservation() {
        self.nowPlayingObservationGeneration &+= 1
        self.observePlaybackState(generation: self.nowPlayingObservationGeneration)
    }

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

    private func syncPlaybackAudioQualitySetting() {
        SingletonPlayerWebView.shared.setPlaybackAudioQuality(self.settings.playbackAudioQuality)
    }

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

        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { _ in
            captureCommand(.play)
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { _ in
            captureCommand(.pause)
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { _ in
            captureCommand(.togglePlayPause)
            return .success
        }

        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { _ in
            captureCommand(.nextPrevious(direction: .forward))
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { _ in
            captureCommand(.nextPrevious(direction: .backward))
            return .success
        }

        commandCenter.skipForwardCommand.isEnabled = self.settings.mediaControlStyle == .skipForwardBackward
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.defaultSkipInterval)]
        commandCenter.skipForwardCommand.addTarget { event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.defaultSkipInterval
            captureCommand(.skip(interval: interval, direction: .forward))
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = self.settings.mediaControlStyle == .skipForwardBackward
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.defaultSkipInterval)]
        commandCenter.skipBackwardCommand.addTarget { event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.defaultSkipInterval
            captureCommand(.skip(interval: interval, direction: .backward))
            return .success
        }

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

    @discardableResult
    func handleAppIntentCommand(_ payload: RemoteMusicCommandPayload) -> Bool {
        guard let player = self.playerService,
              Self.hasTransportTarget(player: player, routesToYouTubeVideo: self.routesToYouTubeVideo)
        else { return false }
        if self.remoteMusicCommandIngress.capture(payload) {
            self.drainRemoteMusicCommandIngress()
        }
        return true
    }

    static func hasTransportTarget(player: PlayerService, routesToYouTubeVideo: Bool) -> Bool {
        routesToYouTubeVideo || player.currentTrack != nil || player.currentEpisode != nil
            || player.pendingPlayVideoId != nil || !player.queueEntries.isEmpty
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
        case let .trackNavigation(direction):
            self.handleTrackChange(
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
        guard self.settings.mediaControlStyle == .skipForwardBackward else {
            self.handleTrackChange(
                direction: direction,
                capturedCommand: capturedCommand,
                player: player
            )
            return
        }

        if self.routesToYouTubeVideo, let youtube = self.youtubePlayerService {
            let delta = direction == .forward ? Self.defaultSkipInterval : -Self.defaultSkipInterval
            youtube.handleRemoteSeek(
                to: max(0, youtube.progress + delta),
                issuedAtMilliseconds: capturedCommand.issuedAtMilliseconds
            )
            return
        }

        self.handleSkipCommand(
            interval: Self.defaultSkipInterval,
            direction: direction,
            capturedCommand: capturedCommand,
            player: player
        )
    }

    private func handleTrackChange(
        direction: RemoteMusicCommandDirection,
        capturedCommand: CapturedRemoteMusicCommand,
        player: PlayerService
    ) {
        if self.routesToYouTubeVideo, let youtube = self.youtubePlayerService {
            if direction == .forward {
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

        self.handleTrackNavigation(
            direction: direction,
            capturedCommand: capturedCommand,
            player: player
        )
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
