import Foundation
import Observation

@MainActor
@Observable
final class PlaybackArbiter {
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

    func musicDidStartPlaying() {
        guard self.activeSource != .music else { return }
        self.activeSource = .music

        guard self.youtubePlayerService.isPlaying else { return }
        self.logger.info("Arbiter: pausing video for music playback")
        self.youtubePlayerService.pause()
    }

    var routesMediaKeysToVideo: Bool {
        self.activeSource == .video && self.youtubePlayerService.currentVideo != nil
    }
}
