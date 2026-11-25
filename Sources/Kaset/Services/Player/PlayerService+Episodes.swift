import Foundation

@MainActor
extension PlayerService {
    var isCurrentItemLive: Bool {
        self.currentEpisode?.isLive ?? false
    }

    func playEpisode(_ episode: ArtistEpisode) async {
        let intent = self.beginMusicPlaybackIntent()
        await self.playEpisode(episode, intent: intent)
    }

    func playEpisode(_ episode: ArtistEpisode, intent: MusicPlaybackIntent) async {
        guard self.acceptsMusicPlaybackIntent(intent) else { return }
        self.logger.info("Playing artist episode: \(episode.title) (live=\(episode.isLive))")

        self.prepareForNewPlaybackContext()

        self.setQueue([])
        self.currentIndex = 0
        self.clearForwardSkipNavigationStack()

        let representative = Song(
            id: episode.videoId,
            title: episode.title,
            artists: [],
            album: nil,
            duration: nil,
            thumbnailURL: episode.thumbnailURL,
            videoId: episode.videoId
        )

        await self.play(
            song: representative,
            webLoadStrategy: .standard,
            episode: episode,
            queueEntryID: nil,
            intent: intent
        )
    }
}
