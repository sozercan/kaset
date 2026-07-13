import Foundation

// MARK: - Queue Playlist Actions

@MainActor
extension PlayerService {
    var currentAccountMutationOwner: MusicAccountMutationOwner {
        MusicAccountMutationOwner(
            accountID: self.songLikeStatusManager.activeAccountID,
            sessionGeneration: self.accountSessionGeneration
        )
    }

    func acceptsAccountMutationOwner(_ owner: MusicAccountMutationOwner) -> Bool {
        owner == self.currentAccountMutationOwner
    }

    /// Creates a private playlist from the current queue and notifies library views.
    func saveQueueAsPlaylist(title: String) async throws -> Playlist {
        let owner = self.currentAccountMutationOwner
        return try await self.saveQueueAsPlaylist(
            title: title,
            songs: self.queue,
            owner: owner
        )
    }

    func saveQueueAsPlaylist(
        title: String,
        songs: [Song],
        owner: MusicAccountMutationOwner
    ) async throws -> Playlist {
        guard let client = self.ytMusicClient else {
            throw YTMusicError.parseError(message: "YouTube Music client is unavailable")
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw YTMusicError.parseError(message: "Playlist name is required")
        }
        guard self.acceptsAccountMutationOwner(owner) else {
            throw CancellationError()
        }

        let videoIds = songs.map(\.videoId)
        let playlistId = try await client.createPlaylist(
            title: trimmedTitle,
            description: nil,
            privacyStatus: .private,
            videoIds: videoIds
        )
        guard self.acceptsAccountMutationOwner(owner) else {
            throw CancellationError()
        }

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
        guard self.acceptsAccountMutationOwner(owner) else {
            LibraryMutationBroadcaster.shared.discardCreatedPlaylist(playlist)
            throw CancellationError()
        }
        SongActionsHelper.invalidateLibraryResponseCaches()
        let didReconcile = await LibraryMutationBroadcaster.shared.reconcileCreatedPlaylist(
            playlist,
            whileValid: { self.acceptsAccountMutationOwner(owner) }
        )
        guard didReconcile, self.acceptsAccountMutationOwner(owner) else {
            LibraryMutationBroadcaster.shared.discardCreatedPlaylist(playlist)
            throw CancellationError()
        }
        SongActionsHelper.invalidateLibraryResponseCaches()

        self.logger.info("Saved queue as playlist '\(trimmedTitle)' with \(songs.count) songs")
        return playlist
    }
}
