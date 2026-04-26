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
    /// thumbnail, then installs `currentEpisode` through the player so the UI
    /// can gate live behavior before metadata loading suspends.
    func playEpisode(_ episode: ArtistEpisode) async {
        self.logger.info("Playing artist episode: \(episode.title) (live=\(episode.isLive))")

        // Live streams / channel videos play standalone — clear queue state.
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

        // Pass the episode into `play` so episode state is installed before
        // any async metadata fetch can suspend. This prevents a stale episode
        // task from marking a later normal track as episode playback.
        await self.play(song: representative, webLoadStrategy: .standard, episode: episode)
    }
}
