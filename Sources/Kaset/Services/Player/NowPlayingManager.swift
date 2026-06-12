import AppKit
import Foundation
import MediaPlayer
import Observation
import os

/// Manages remote command center integration for media key support.
/// Note: Now Playing info display is handled natively by WKWebView's media session.
/// This class only sets up remote command handlers to route media keys to our PlayerService.
@MainActor
@Observable
final class NowPlayingManager {
    /// Shared singleton instance. Must be configured with `configure(playerService:)` before use.
    static let shared = NowPlayingManager()

    private var playerService: PlayerService?
    private let logger = DiagnosticsLogger.player
    private var isConfigured = false

    /// YouTube video routing (optional; absent in music-only flows).
    /// When the arbiter says the video source played last, play/pause/toggle
    /// media keys control it instead of the music player. Guarded so music
    /// behavior is identical when video routing is not configured/active.
    private weak var youtubePlayerService: YouTubePlayerService?
    private weak var playbackArbiter: PlaybackArbiter?
    private let settings = SettingsManager.shared
    private static let defaultSkipInterval: TimeInterval = 15
    private static let skipTargetCoalescingWindow: Duration = .seconds(1)
    private var lastSkipTarget: TimeInterval?
    private var lastSkipVideoId: String?
    private var lastSkipIssuedAt: ContinuousClock.Instant?

    private init() {}

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
        self.logger.info("NowPlayingManager configured (remote commands only)")

        self.observeSettingsChanges()
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
        self.logger.info("NowPlayingManager: YouTube video routing configured")
    }

    /// Whether play/pause media keys should control the YouTube video player.
    private var routesToYouTubeVideo: Bool {
        self.playbackArbiter?.routesMediaKeysToVideo == true
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
        guard let player = playerService else { return }
        let commandCenter = MPRemoteCommandCenter.shared()
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
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                if let self, self.routesToYouTubeVideo, let youtube = self.youtubePlayerService {
                    youtube.resume()
                } else {
                    await player.resume()
                }
            }
            return .success
        }

        // Pause command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                if let self, self.routesToYouTubeVideo, let youtube = self.youtubePlayerService {
                    youtube.pause()
                } else {
                    await player.pause()
                }
            }
            return .success
        }

        // Toggle play/pause command
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                if let self, self.routesToYouTubeVideo, let youtube = self.youtubePlayerService {
                    youtube.playPause()
                } else {
                    await player.playPause()
                }
            }
            return .success
        }

        // Next track command
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                await self.handleNextPreviousMediaKey(direction: .forward, player: player)
            }
            return .success
        }

        // Previous track command
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                await self.handleNextPreviousMediaKey(direction: .backward, player: player)
            }
            return .success
        }

        // Skip forward command (Control Center skip buttons or media keys)
        commandCenter.skipForwardCommand.isEnabled = self.settings.mediaControlStyle == .skipForwardBackward
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.defaultSkipInterval)]
        commandCenter.skipForwardCommand.addTarget { [weak self] event in
            guard let self else { return .commandFailed }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.defaultSkipInterval
            Task { @MainActor in
                await self.handleSkipCommand(interval: interval, direction: .forward, player: player)
            }
            return .success
        }

        // Skip backward command (Control Center skip buttons or media keys)
        commandCenter.skipBackwardCommand.isEnabled = self.settings.mediaControlStyle == .skipForwardBackward
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.defaultSkipInterval)]
        commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            guard let self else { return .commandFailed }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.defaultSkipInterval
            Task { @MainActor in
                await self.handleSkipCommand(interval: interval, direction: .backward, player: player)
            }
            return .success
        }

        // Change playback position command
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self else { return .commandFailed }
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = positionEvent.positionTime
            Task { @MainActor in
                self.clearSkipCoalescingTarget()
                await player.seek(to: position)
            }
            return .success
        }

        self.logger.info("Remote commands configured")
    }

    private enum SkipDirection {
        case forward
        case backward
    }

    private func handleNextPreviousMediaKey(direction: SkipDirection, player: PlayerService) async {
        if self.settings.mediaControlStyle == .skipForwardBackward {
            await self.handleSkipCommand(interval: Self.defaultSkipInterval, direction: direction, player: player)
        } else {
            await self.handleTrackNavigation(direction: direction, player: player)
        }
    }

    private func handleSkipCommand(
        interval: TimeInterval,
        direction: SkipDirection,
        player: PlayerService
    ) async {
        guard player.currentTrack != nil || player.pendingPlayVideoId != nil || !player.queue.isEmpty else {
            return
        }

        if self.settings.mediaControlStyle == .nextPreviousTrack {
            await self.handleTrackNavigation(direction: direction, player: player)
            return
        }

        let now = ContinuousClock.now
        let currentVideoId = player.currentTrack?.videoId ?? player.pendingPlayVideoId
        if let currentVideoId {
            if self.lastSkipVideoId != currentVideoId {
                self.clearSkipCoalescingTarget()
            }
            self.lastSkipVideoId = currentVideoId
        }

        guard let playbackSnapshot = await SingletonPlayerWebView.shared.currentPlaybackSnapshot(),
              self.playbackSnapshot(playbackSnapshot, matches: currentVideoId)
        else {
            self.clearSkipCoalescingTarget()
            return
        }

        let reportedProgress = playbackSnapshot.progress
        let reportedDuration = playbackSnapshot.duration

        // WebView progress can lag behind rapid media-key repeats. Briefly use the cached
        // target so repeated or reversed skips accumulate before stale observer updates land.
        let baseProgress = if self.canCoalesceSkipTarget(at: now), let lastSkipTarget = self.lastSkipTarget {
            lastSkipTarget
        } else {
            reportedProgress
        }

        let rawTarget = switch direction {
        case .forward:
            baseProgress + interval
        case .backward:
            baseProgress - interval
        }
        let target = if reportedDuration > 0 {
            min(max(0, rawTarget), reportedDuration)
        } else {
            max(0, rawTarget)
        }

        self.lastSkipTarget = target
        self.lastSkipIssuedAt = now
        player.progress = target
        await player.seek(to: target)
    }

    private func playbackSnapshot(
        _ snapshot: SingletonPlayerWebView.PlaybackSnapshot?,
        matches currentVideoId: String?
    ) -> Bool {
        guard let snapshotVideoId = snapshot?.videoId, let currentVideoId else { return true }
        return snapshotVideoId == currentVideoId
    }

    private func handleTrackNavigation(direction: SkipDirection, player: PlayerService) async {
        self.clearSkipCoalescingTarget()
        switch direction {
        case .forward:
            await player.next()
        case .backward:
            await player.previous()
        }
    }

    private func canCoalesceSkipTarget(at now: ContinuousClock.Instant) -> Bool {
        guard let lastSkipIssuedAt = self.lastSkipIssuedAt else { return false }
        return now - lastSkipIssuedAt <= Self.skipTargetCoalescingWindow
    }

    private func clearSkipCoalescingTarget() {
        self.lastSkipTarget = nil
        self.lastSkipIssuedAt = nil
    }
}
