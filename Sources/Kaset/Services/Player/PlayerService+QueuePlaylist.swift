import Foundation

// MARK: - Queue Playlist Actions

@MainActor
extension PlayerService {
    /// Creates a private playlist from the current queue and notifies library views.
    func saveQueueAsPlaylist(title: String) async throws -> Playlist {
        guard let client = self.ytMusicClient else {
            throw YTMusicError.parseError(message: "YouTube Music client is unavailable")
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw YTMusicError.parseError(message: "Playlist name is required")
        }

        let songs = self.queue
        let videoIds = songs.map(\.videoId)
        let playlistId = try await client.createPlaylist(
            title: trimmedTitle,
            description: nil,
            privacyStatus: .private,
            videoIds: videoIds
        )

        let playlist = Playlist(
            id: playlistId,
            title: trimmedTitle,
            description: nil,
            thumbnailURL: songs.first?.thumbnailURL,
            trackCount: songs.count
        )

        SongActionsHelper.invalidateLibraryResponseCaches()
        LibraryMutationBroadcaster.shared.playlistCreated(playlist)

        try? await Task.sleep(for: .milliseconds(500))
        SongActionsHelper.invalidateLibraryResponseCaches()
        await LibraryMutationBroadcaster.shared.reconcileCreatedPlaylist(playlist)
        SongActionsHelper.invalidateLibraryResponseCaches()

        self.logger.info("Saved queue as playlist '\(trimmedTitle)' with \(songs.count) songs")
        return playlist
    }
}
