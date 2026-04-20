import Foundation

// MARK: - Artist-Page Episode Playback

@MainActor
extension PlayerService {
    /// Convenience flag for UI gating (disables seek/queue UI for live streams).
    var isCurrentItemLive: Bool {
        self.currentEpisode?.isLive ?? false
    }

    /// Plays an artist-page episode as a standalone item (not enqueued).
    ///
    /// Episodes — including live radio streams from channel-style artists —
    /// don't belong in the song queue: they have no duration, can't be
    /// seeked, and next/previous has no meaning. This clears the queue,
    /// synthesizes a minimal `Song` so `PlayerBar` can render title and
    /// thumbnail, then assigns `currentEpisode` so the UI can gate live
    /// behavior.
    func playEpisode(_ episode: ArtistEpisode) async {
        self.logger.info("Playing artist episode: \(episode.title) (live=\(episode.isLive))")

        // Live streams / channel videos play standalone — clear queue state.
        self.queue = []
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

        // `play(song:)` resets `currentEpisode = nil`; reassign it afterwards.
        await self.play(song: representative)
        self.currentEpisode = episode
    }
}
