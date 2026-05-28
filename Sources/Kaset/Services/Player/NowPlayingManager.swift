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
    private let settings = SettingsManager.shared
    private static let defaultSkipInterval: TimeInterval = 15

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
        commandCenter.playCommand.addTarget { _ in
            Task { @MainActor in
                await player.resume()
            }
            return .success
        }

        // Pause command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { _ in
            Task { @MainActor in
                await player.pause()
            }
            return .success
        }

        // Toggle play/pause command
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in
                await player.playPause()
            }
            return .success
        }

        // Next track command
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { _ in
            Task { @MainActor in
                await player.next()
            }
            return .success
        }

        // Previous track command
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { _ in
            Task { @MainActor in
                await player.previous()
            }
            return .success
        }

        // Skip forward command (Control Center skip buttons or media keys)
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.defaultSkipInterval)]
        commandCenter.skipForwardCommand.addTarget { [weak self] event in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                await self.handleSkipCommand(event: event, direction: .forward, player: player)
            }
            return .success
        }

        // Skip backward command (Control Center skip buttons or media keys)
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.defaultSkipInterval)]
        commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                await self.handleSkipCommand(event: event, direction: .backward, player: player)
            }
            return .success
        }

        // Change playback position command
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = positionEvent.positionTime
            Task { @MainActor in
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

    private func handleSkipCommand(
        event: MPRemoteCommandEvent,
        direction: SkipDirection,
        player: PlayerService
    ) async {
        if self.settings.mediaControlStyle == .nextPreviousTrack {
            switch direction {
            case .forward:
                await player.next()
            case .backward:
                await player.previous()
            }
            return
        }

        let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.defaultSkipInterval
        let target = switch direction {
        case .forward:
            player.progress + interval
        case .backward:
            player.progress - interval
        }
        await player.seek(to: target)
    }
}
