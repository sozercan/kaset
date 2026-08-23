import Foundation
import Observation

// MARK: - PlaybackArbiter

/// Ensures exactly one audio source plays at a time: starting YouTube video
/// playback pauses music, and starting music pauses video.
///
/// `PlayerService` (music) is intentionally not modified — KasetApp calls
/// `musicDidStartPlaying()` from its existing `onChange(of: isPlaying)`
/// hook, and `YouTubePlayerService` invokes `playbackWillStart` before any
/// video playback begins.
@MainActor
@Observable
final class PlaybackArbiter {
    /// The source that most recently started playback. Media keys route here.
    private(set) var activeSource: AppSource = .music

    private let playerService: PlayerService
    private let youtubePlayerService: YouTubePlayerService
    private let logger = DiagnosticsLogger.player

    init(playerService: PlayerService, youtubePlayerService: YouTubePlayerService) {
        self.playerService = playerService
        self.youtubePlayerService = youtubePlayerService

        youtubePlayerService.playbackWillStart = { [weak self] in
            self?.videoWillStartPlaying()
        }
    }

    /// Video playback is about to start — pause music.
    func videoWillStartPlaying() {
        self.activeSource = .video
        let intent = self.playerService.beginMusicPlaybackIntent()

        let hasActiveOrPendingMusic = self.playerService.isPlaying
            || self.playerService.state == .loading
            || self.playerService.isAwaitingPlaybackConfirmation
            || self.playerService.pendingPlayVideoId != nil
        guard hasActiveOrPendingMusic else { return }
        self.logger.info("Arbiter: pausing music for video playback")
        Task {
            await self.playerService.pause(intent: intent)
        }
    }

    /// Music playback started — pause video (call from KasetApp's existing
    /// `onChange(of: playerService.isPlaying)` hook).
    func musicDidStartPlaying() {
        guard self.activeSource != .music else { return }
        self.activeSource = .music

        guard self.youtubePlayerService.isPlaying else { return }
        self.logger.info("Arbiter: pausing video for music playback")
        self.youtubePlayerService.pause()
    }

    /// Whether media keys should currently control the YouTube video player.
    var routesMediaKeysToVideo: Bool {
        self.activeSource == .video && self.youtubePlayerService.currentVideo != nil
    }
}
