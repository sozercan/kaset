import Foundation

/// Orchestrates Library mutations that need optimistic UI updates, cache invalidation,
/// and eventual-consistency reconciliation after YouTube Music accepts a change.
@MainActor
enum LibraryMutationActions {
    private struct PlaylistDeletionKey: Hashable {
        let playlistId: String
        let owner: MusicAccountMutationOwner?
    }

    private struct PendingPlaylistDeletion {
        let id: UUID
        let task: Task<Void, Error>
    }

    static var artistReconciliationRetryDelays: [Duration] = [.seconds(2), .seconds(3)]

    private static var artistReconciliationTasks: [String: Task<Void, Never>] = [:]
    private static var pendingPlaylistDeletions: [PlaylistDeletionKey: PendingPlaylistDeletion] = [:]

    /// Adds a song to a playlist.
    static func addSongToPlaylist(
        _ song: Song,
        playlist: AddToPlaylistOption,
        client: any YTMusicClientProtocol
    ) async {
        do {
            try await client.addSongToPlaylist(
                videoId: song.videoId,
                playlistId: playlist.playlistId,
                allowDuplicate: false
            )
            self.invalidateResponseCaches()
            DiagnosticsLogger.api.info("Added song '\(song.title)' to playlist '\(playlist.title)'")
        } catch {
            DiagnosticsLogger.api.error("Failed to add song to playlist: \(error.localizedDescription)")
        }
    }

    /// Removes a song from the playlist currently loaded in `viewModel`. The row is removed
    /// optimistically and restored if the server mutation fails.
    static func removeSongFromPlaylist(
        _ song: Song,
        from viewModel: PlaylistDetailViewModel,
        client: any YTMusicClientProtocol
    ) async {
        guard let setVideoId = song.playlistSetVideoId else {
            DiagnosticsLogger.api.error("Cannot remove '\(song.title)' from playlist: missing setVideoId")
            HapticService.error()
            return
        }
        guard let removal = viewModel.beginOptimisticTrackRemoval(setVideoId: setVideoId) else { return }

        do {
            try Task.checkCancellation()
            try await client.removeSongFromPlaylist(
                videoId: song.videoId,
                setVideoId: setVideoId,
                playlistId: viewModel.playlistID
            )
            Self.invalidateResponseCaches()
            viewModel.confirmTrackRemoval(removal)
            HapticService.success()
            DiagnosticsLogger.api.info("Removed song '\(song.title)' from playlist")
        } catch is CancellationError {
            await viewModel.rollbackTrackRemoval(removal)
            return
        } catch {
            await viewModel.rollbackTrackRemoval(removal)
            HapticService.error()
            DiagnosticsLogger.api.error("Failed to remove song from playlist: \(error.localizedDescription)")
        }
    }

    /// Adds a playlist to the library.
    static func addPlaylistToLibrary(
        _ playlist: Playlist,
        client: any YTMusicClientProtocol,
        libraryViewModel: LibraryViewModel?
    ) async {
        do {
            try await client.subscribeToPlaylist(playlistId: playlist.id)
            self.invalidateResponseCaches()
            libraryViewModel?.markNeedsReloadOnActivation()
            if let libraryViewModel {
                libraryViewModel.addToLibrary(playlist: playlist)
                // Library browse responses can lag briefly behind a successful add.
                try? await Task.sleep(for: .milliseconds(500))
                await libraryViewModel.refresh()
                self.invalidateResponseCaches()

                if !libraryViewModel.isInLibrary(playlistId: playlist.id) {
                    libraryViewModel.addToLibrary(playlist: playlist)
                    self.invalidateResponseCaches()
                }
            }
            DiagnosticsLogger.api.info("Added playlist to library: \(playlist.title)")
        } catch {
            DiagnosticsLogger.api.error("Failed to add playlist to library: \(error.localizedDescription)")
        }
    }

    /// Removes a playlist from the library.
    static func removePlaylistFromLibrary(
        _ playlist: Playlist,
        client: any YTMusicClientProtocol,
        libraryViewModel: LibraryViewModel?
    ) async {
        do {
            try await client.unsubscribeFromPlaylist(playlistId: playlist.id)
            self.invalidateResponseCaches()
            libraryViewModel?.markNeedsReloadOnActivation()
            LibraryMutationBroadcaster.shared.playlistRemoved(playlistId: playlist.id)

            // Library browse responses can lag briefly behind a successful removal.
            try? await Task.sleep(for: .milliseconds(500))
            await LibraryMutationBroadcaster.shared.reconcileRemovedPlaylist(playlistId: playlist.id)
            self.invalidateResponseCaches()
            DiagnosticsLogger.api.info("Removed playlist from library: \(playlist.title)")
        } catch {
            DiagnosticsLogger.api.error("Failed to remove playlist from library: \(error.localizedDescription)")
        }
    }

    /// Permanently deletes a playlist owned by the user.
    static func deletePlaylist(
        _ playlist: Playlist,
        client: any YTMusicClientProtocol,
        libraryViewModel: LibraryViewModel?,
        owner: MusicAccountMutationOwner? = nil,
        whileValid isCurrent: @escaping () -> Bool = { true }
    ) async throws {
        guard isCurrent() else { throw CancellationError() }
        let key = PlaylistDeletionKey(
            playlistId: LibraryContentIdentity.playlistKey(for: playlist.id),
            owner: owner
        )
        if let pendingDeletion = self.pendingPlaylistDeletions[key] {
            try await pendingDeletion.task.value
            return
        }

        let operationID = UUID()
        let removedPins = SidebarPinnedItemsManager.shared.removePlaylistPins(matching: playlist.id)
        let removalReceipt = LibraryMutationBroadcaster.shared.playlistRemoved(
            playlistId: playlist.id
        )
        let task = Task { @MainActor in
            var didDeleteRemotely = false
            do {
                guard isCurrent() else { throw CancellationError() }
                try await client.deletePlaylist(playlistId: playlist.id)
                didDeleteRemotely = true
                guard isCurrent() else { throw CancellationError() }
                self.invalidateResponseCaches()
                libraryViewModel?.markNeedsReloadOnActivation()
                DiagnosticsLogger.api.info("Deleted playlist: \(playlist.title)")

                // Library browse responses can lag briefly behind a successful deletion.
                try? await Task.sleep(for: .milliseconds(500))
                guard isCurrent() else { throw CancellationError() }
                await LibraryMutationBroadcaster.shared.reconcileRemovedPlaylist(playlistId: playlist.id)
                self.invalidateResponseCaches()
            } catch {
                guard isCurrent() else {
                    if !didDeleteRemotely {
                        SidebarPinnedItemsManager.shared.restore(removedPins)
                    }
                    throw CancellationError()
                }
                SidebarPinnedItemsManager.shared.restore(removedPins)
                LibraryMutationBroadcaster.shared.rollbackPlaylistRemoval(
                    playlist,
                    receipt: removalReceipt
                )
                DiagnosticsLogger.api.error("Failed to delete playlist: \(error.localizedDescription)")
                throw error
            }
        }
        self.pendingPlaylistDeletions[key] = PendingPlaylistDeletion(
            id: operationID,
            task: task
        )
        defer {
            if self.pendingPlaylistDeletions[key]?.id == operationID {
                self.pendingPlaylistDeletions.removeValue(forKey: key)
            }
        }
        try await task.value
    }

    /// Subscribes to a podcast show (adds to library).
    static func subscribeToPodcast(
        _ show: PodcastShow,
        client: any YTMusicClientProtocol,
        libraryViewModel: LibraryViewModel?
    ) async throws {
        try await client.subscribeToPodcast(showId: show.id)
        self.invalidateResponseCaches()
        libraryViewModel?.markNeedsReloadOnActivation()
        if let libraryViewModel {
            libraryViewModel.addToLibrary(podcast: show)

            // Library browse responses can lag briefly behind a successful subscribe.
            try? await Task.sleep(for: .milliseconds(500))
            await libraryViewModel.refresh()
            self.invalidateResponseCaches()

            if !libraryViewModel.isInLibrary(podcastId: show.id) {
                libraryViewModel.addToLibrary(podcast: show)
                self.invalidateResponseCaches()
            }
        }
        DiagnosticsLogger.api.info("Subscribed to podcast: \(show.title)")
    }

    /// Unsubscribes from a podcast show (removes from library).
    static func unsubscribeFromPodcast(
        _ show: PodcastShow,
        client: any YTMusicClientProtocol,
        libraryViewModel: LibraryViewModel?
    ) async throws {
        DiagnosticsLogger.api.debug("Attempting to unsubscribe from podcast: \(show.id), libraryViewModel is \(libraryViewModel == nil ? "nil" : "present")")
        try await client.unsubscribeFromPodcast(showId: show.id)
        self.invalidateResponseCaches()
        libraryViewModel?.markNeedsReloadOnActivation()
        if let libraryViewModel {
            libraryViewModel.removeFromLibrary(podcastId: show.id)

            // Library browse responses can lag briefly behind a successful removal.
            try? await Task.sleep(for: .milliseconds(500))
            await libraryViewModel.refresh()
            self.invalidateResponseCaches()

            if libraryViewModel.isInLibrary(podcastId: show.id) {
                libraryViewModel.removeFromLibrary(podcastId: show.id)
                self.invalidateResponseCaches()
            }
        }
        DiagnosticsLogger.api.info("Unsubscribed from podcast: \(show.title)")
    }

    /// Subscribes to an artist (adds to library).
    static func subscribeToArtist(
        _ artist: Artist,
        channelId: String,
        client: any YTMusicClientProtocol,
        libraryViewModel: LibraryViewModel?
    ) async throws {
        if let libraryViewModel {
            self.addArtistToLibrary(artist, channelId: channelId, libraryViewModel: libraryViewModel)
            libraryViewModel.markNeedsReloadOnActivation()
        }

        do {
            try await client.subscribeToArtist(channelId: channelId)
            Self.invalidateResponseCaches()
            if let libraryViewModel {
                Self.scheduleArtistReconciliation(
                    artist,
                    channelId: channelId,
                    expectedInLibrary: true,
                    libraryViewModel: libraryViewModel
                )
            }
            DiagnosticsLogger.api.info("Subscribed to artist: \(artist.name)")
        } catch {
            if let libraryViewModel {
                Self.removeArtistFromLibrary(artist, channelId: channelId, libraryViewModel: libraryViewModel)
                libraryViewModel.markNeedsReloadOnActivation()
            }
            DiagnosticsLogger.api.error("Failed to subscribe to artist: \(error.localizedDescription)")
            throw error
        }
    }

    /// Unsubscribes from an artist (removes from library).
    static func unsubscribeFromArtist(
        _ artist: Artist,
        channelId: String,
        client: any YTMusicClientProtocol,
        libraryViewModel: LibraryViewModel?
    ) async throws {
        if let libraryViewModel {
            self.removeArtistFromLibrary(artist, channelId: channelId, libraryViewModel: libraryViewModel)
            libraryViewModel.markNeedsReloadOnActivation()
        }

        do {
            try await client.unsubscribeFromArtist(channelId: channelId)
            Self.invalidateResponseCaches()
            if let libraryViewModel {
                Self.scheduleArtistReconciliation(
                    artist,
                    channelId: channelId,
                    expectedInLibrary: false,
                    libraryViewModel: libraryViewModel
                )
            }
            DiagnosticsLogger.api.info("Unsubscribed from artist: \(artist.name)")
        } catch {
            if let libraryViewModel {
                Self.addArtistToLibrary(artist, channelId: channelId, libraryViewModel: libraryViewModel)
                libraryViewModel.markNeedsReloadOnActivation()
            }
            DiagnosticsLogger.api.error("Failed to unsubscribe from artist: \(error.localizedDescription)")
            throw error
        }
    }

    static func invalidateResponseCaches() {
        // Library mutations can leave stale data in both the app-level cache and URL loading cache.
        APICache.shared.invalidate(matching: "browse:")
        APICache.shared.invalidate(matching: "playlist/get_add_to_playlist:")
        URLCache.shared.removeAllCachedResponses()
    }

    private static func scheduleArtistReconciliation(
        _ artist: Artist,
        channelId: String,
        expectedInLibrary: Bool,
        libraryViewModel: LibraryViewModel
    ) {
        let normalizedArtistId = Artist.publicChannelId(for: channelId) ?? channelId
        Self.artistReconciliationTasks[normalizedArtistId]?.cancel()

        Self.artistReconciliationTasks[normalizedArtistId] = Task { @MainActor in
            defer { Self.artistReconciliationTasks.removeValue(forKey: normalizedArtistId) }

            for delay in Self.artistReconciliationRetryDelays {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }

                guard !Task.isCancelled else { return }

                Self.invalidateResponseCaches()
                await libraryViewModel.refresh()
                Self.invalidateResponseCaches()

                let needsReconciliation = libraryViewModel.needsArtistLibraryReconciliation(
                    artistIds: Self.artistLibraryAliases(for: artist, channelId: channelId),
                    expectedInLibrary: expectedInLibrary
                )
                let isInLibrary = Self.isArtistInLibrary(
                    artist,
                    channelId: channelId,
                    libraryViewModel: libraryViewModel
                )
                if !needsReconciliation, isInLibrary == expectedInLibrary {
                    DiagnosticsLogger.api.debug(
                        "Artist library reconciliation converged with backend state for \(artist.name, privacy: .public)"
                    )
                    return
                }

                DiagnosticsLogger.api.debug(
                    "Artist library reconciliation is still waiting on backend propagation for \(artist.name, privacy: .public)"
                )
                if isInLibrary != expectedInLibrary {
                    DiagnosticsLogger.api.debug(
                        "Artist library reconciliation is reapplying optimistic state for \(artist.name, privacy: .public)"
                    )
                }

                if expectedInLibrary {
                    Self.addArtistToLibrary(artist, channelId: channelId, libraryViewModel: libraryViewModel)
                } else {
                    Self.removeArtistFromLibrary(artist, channelId: channelId, libraryViewModel: libraryViewModel)
                }
                libraryViewModel.markNeedsReloadOnActivation()
            }
        }
    }

    private static func addArtistToLibrary(
        _ artist: Artist,
        channelId: String,
        libraryViewModel: LibraryViewModel
    ) {
        let libraryArtistId = Self.preferredLibraryArtistId(for: artist, channelId: channelId)
        libraryViewModel.addToLibrary(artist: artist, libraryArtistId: libraryArtistId)
        for artistId in Self.artistLibraryAliases(for: artist, channelId: channelId) {
            libraryViewModel.addToLibrarySet(artistId: artistId)
        }
    }

    private static func removeArtistFromLibrary(
        _ artist: Artist,
        channelId: String,
        libraryViewModel: LibraryViewModel
    ) {
        for artistId in self.artistLibraryAliases(for: artist, channelId: channelId) {
            libraryViewModel.removeFromLibrary(artistId: artistId)
        }
    }

    private static func isArtistInLibrary(
        _ artist: Artist,
        channelId: String,
        libraryViewModel: LibraryViewModel
    ) -> Bool {
        self.artistLibraryAliases(for: artist, channelId: channelId)
            .contains(where: { libraryViewModel.isInLibrary(artistId: $0) })
    }

    private static func artistLibraryAliases(for artist: Artist, channelId: String) -> [String] {
        var ids = Set([channelId, artist.id])
        if let publicChannelId = artist.publicChannelId {
            ids.insert(publicChannelId)
        }
        return Array(ids)
    }

    private static func preferredLibraryArtistId(for artist: Artist, channelId: String) -> String {
        if artist.hasNavigableId {
            return artist.id
        }

        return channelId
    }
}
