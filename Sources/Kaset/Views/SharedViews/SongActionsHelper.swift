// swiftlint:disable file_length
import AppKit
import Foundation
import SwiftUI

// MARK: - SongActionsHelper

/// Helper for common song actions like liking, disliking, adding to library, and queue management.
@MainActor
enum SongActionsHelper {
    static var artistLibraryReconciliationRetryDelays: [Duration] = [.seconds(2), .seconds(3)]

    private static var artistLibraryReconciliationTasks: [String: Task<Void, Never>] = [:]

    private static func cleanedArtistPreservingMetadata(_ artist: Artist) -> Artist? {
        var cleanName = artist.name

        if cleanName == "Album" {
            return nil
        }

        if cleanName.hasPrefix("Album, ") {
            cleanName = String(cleanName.dropFirst(7))
        }

        return Artist(
            id: artist.id,
            name: cleanName,
            thumbnailURL: artist.thumbnailURL,
            subtitle: artist.subtitle,
            profileKind: artist.profileKind
        )
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

    private static func scheduleArtistLibraryReconciliation(
        _ artist: Artist,
        channelId: String,
        expectedInLibrary: Bool,
        libraryViewModel: LibraryViewModel
    ) {
        let normalizedArtistId = Artist.publicChannelId(for: channelId) ?? channelId
        self.artistLibraryReconciliationTasks[normalizedArtistId]?.cancel()

        self.artistLibraryReconciliationTasks[normalizedArtistId] = Task { @MainActor in
            defer { self.artistLibraryReconciliationTasks.removeValue(forKey: normalizedArtistId) }

            for delay in self.artistLibraryReconciliationRetryDelays {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }

                guard !Task.isCancelled else { return }

                self.invalidateLibraryResponseCaches()
                await libraryViewModel.refresh()
                self.invalidateLibraryResponseCaches()

                let needsReconciliation = libraryViewModel.needsArtistLibraryReconciliation(
                    artistIds: self.artistLibraryAliases(for: artist, channelId: channelId),
                    expectedInLibrary: expectedInLibrary
                )
                let isInLibrary = self.isArtistInLibrary(
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
                    self.addArtistToLibrary(artist, channelId: channelId, libraryViewModel: libraryViewModel)
                } else {
                    self.removeArtistFromLibrary(artist, channelId: channelId, libraryViewModel: libraryViewModel)
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
        let libraryArtistId = self.preferredLibraryArtistId(for: artist, channelId: channelId)
        libraryViewModel.addToLibrary(artist: artist, libraryArtistId: libraryArtistId)
        for artistId in self.artistLibraryAliases(for: artist, channelId: channelId) {
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

    /// Likes a song via the API (does not play the song).
    static func likeSong(_ song: Song, likeStatusManager: SongLikeStatusManager) {
        let activeAccountID = likeStatusManager.activeAccountID
        Task {
            await likeStatusManager.like(song, accountID: activeAccountID)
        }
    }

    /// Unlikes a song (removes the like rating) via the API.
    static func unlikeSong(_ song: Song, likeStatusManager: SongLikeStatusManager) {
        let activeAccountID = likeStatusManager.activeAccountID
        Task {
            await likeStatusManager.unlike(song, accountID: activeAccountID)
        }
    }

    /// Dislikes a song via the API (does not play the song).
    static func dislikeSong(_ song: Song, likeStatusManager: SongLikeStatusManager) {
        let activeAccountID = likeStatusManager.activeAccountID
        Task {
            await likeStatusManager.dislike(song, accountID: activeAccountID)
        }
    }

    /// Undislikes a song (removes the dislike rating) via the API.
    static func undislikeSong(_ song: Song, likeStatusManager: SongLikeStatusManager) {
        let activeAccountID = likeStatusManager.activeAccountID
        Task {
            await likeStatusManager.undislike(song, accountID: activeAccountID)
        }
    }

    /// Adds a song to the library by playing it and toggling library status.
    /// Note: This still requires playing because library toggle works on current track.
    static func addToLibrary(_ song: Song, playerService: PlayerService) {
        Task {
            await playerService.play(song: song)
            try? await Task.sleep(for: .milliseconds(100))
            playerService.toggleLibraryStatus()
        }
    }

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
            self.invalidateLibraryResponseCaches()
            DiagnosticsLogger.api.info("Added song '\(song.title)' to playlist '\(playlist.title)'")
        } catch {
            DiagnosticsLogger.api.error("Failed to add song to playlist: \(error.localizedDescription)")
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
            self.invalidateLibraryResponseCaches()
            libraryViewModel?.markNeedsReloadOnActivation()
            if let libraryViewModel {
                libraryViewModel.addToLibrary(playlist: playlist)
                // Library browse responses can lag briefly behind a successful add.
                try? await Task.sleep(for: .milliseconds(500))
                await libraryViewModel.refresh()
                self.invalidateLibraryResponseCaches()

                if !libraryViewModel.isInLibrary(playlistId: playlist.id) {
                    libraryViewModel.addToLibrary(playlist: playlist)
                    self.invalidateLibraryResponseCaches()
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
            self.invalidateLibraryResponseCaches()
            libraryViewModel?.markNeedsReloadOnActivation()
            if let libraryViewModel {
                libraryViewModel.removeFromLibrary(playlistId: playlist.id)

                // Library browse responses can lag briefly behind a successful removal.
                try? await Task.sleep(for: .milliseconds(500))
                await libraryViewModel.refresh()
                self.invalidateLibraryResponseCaches()

                if libraryViewModel.isInLibrary(playlistId: playlist.id) {
                    libraryViewModel.removeFromLibrary(playlistId: playlist.id)
                    self.invalidateLibraryResponseCaches()
                }
            }
            DiagnosticsLogger.api.info("Removed playlist from library: \(playlist.title)")
        } catch {
            DiagnosticsLogger.api.error("Failed to remove playlist from library: \(error.localizedDescription)")
        }
    }

    /// Permanently deletes a playlist owned by the user.
    static func deletePlaylist(
        _ playlist: Playlist,
        client: any YTMusicClientProtocol,
        libraryViewModel: LibraryViewModel?
    ) async throws {
        do {
            try await client.deletePlaylist(playlistId: playlist.id)
            self.invalidateLibraryResponseCaches()
            libraryViewModel?.markNeedsReloadOnActivation()
            if let libraryViewModel {
                libraryViewModel.removeFromLibrary(playlistId: playlist.id)

                // Library browse responses can lag briefly behind a successful deletion.
                try? await Task.sleep(for: .milliseconds(500))
                await libraryViewModel.refresh()
                self.invalidateLibraryResponseCaches()

                if libraryViewModel.isInLibrary(playlistId: playlist.id) {
                    libraryViewModel.removeFromLibrary(playlistId: playlist.id)
                    self.invalidateLibraryResponseCaches()
                }
            }
            DiagnosticsLogger.api.info("Deleted playlist: \(playlist.title)")
        } catch {
            DiagnosticsLogger.api.error("Failed to delete playlist: \(error.localizedDescription)")
            throw error
        }
    }

    /// Shows a confirmation dialog before permanently deleting a playlist owned by the user.
    static func confirmDeletePlaylist(
        _ playlist: Playlist,
        client: any YTMusicClientProtocol,
        libraryViewModel: LibraryViewModel?,
        onSuccess: (() -> Void)? = nil
    ) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(playlist.title)”?"
        alert.informativeText = "This permanently deletes the playlist from YouTube Music. You can only delete playlists you created."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Playlist")
        alert.addButton(withTitle: "Cancel")

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }

            Task { @MainActor in
                do {
                    try await self.deletePlaylist(
                        playlist,
                        client: client,
                        libraryViewModel: libraryViewModel
                    )
                    onSuccess?()
                } catch {
                    self.presentPlaylistDeletionError(error)
                }
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }

    private static func presentPlaylistDeletionError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Unable to Delete Playlist"
        alert.informativeText = "Make sure this is a playlist you created, then try again.\n\n\(error.localizedDescription)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// Subscribes to a podcast show (adds to library).
    static func subscribeToPodcast(
        _ show: PodcastShow,
        client: any YTMusicClientProtocol,
        libraryViewModel: LibraryViewModel?
    ) async throws {
        try await client.subscribeToPodcast(showId: show.id)
        self.invalidateLibraryResponseCaches()
        libraryViewModel?.markNeedsReloadOnActivation()
        if let libraryViewModel {
            libraryViewModel.addToLibrary(podcast: show)

            // Library browse responses can lag briefly behind a successful subscribe.
            try? await Task.sleep(for: .milliseconds(500))
            await libraryViewModel.refresh()
            self.invalidateLibraryResponseCaches()

            if !libraryViewModel.isInLibrary(podcastId: show.id) {
                libraryViewModel.addToLibrary(podcast: show)
                self.invalidateLibraryResponseCaches()
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
        self.invalidateLibraryResponseCaches()
        libraryViewModel?.markNeedsReloadOnActivation()
        if let libraryViewModel {
            libraryViewModel.removeFromLibrary(podcastId: show.id)

            // Library browse responses can lag briefly behind a successful removal.
            try? await Task.sleep(for: .milliseconds(500))
            await libraryViewModel.refresh()
            self.invalidateLibraryResponseCaches()

            if libraryViewModel.isInLibrary(podcastId: show.id) {
                libraryViewModel.removeFromLibrary(podcastId: show.id)
                self.invalidateLibraryResponseCaches()
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
            self.invalidateLibraryResponseCaches()
            if let libraryViewModel {
                self.scheduleArtistLibraryReconciliation(
                    artist,
                    channelId: channelId,
                    expectedInLibrary: true,
                    libraryViewModel: libraryViewModel
                )
            }
            DiagnosticsLogger.api.info("Subscribed to artist: \(artist.name)")
        } catch {
            if let libraryViewModel {
                self.removeArtistFromLibrary(artist, channelId: channelId, libraryViewModel: libraryViewModel)
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
            self.invalidateLibraryResponseCaches()
            if let libraryViewModel {
                self.scheduleArtistLibraryReconciliation(
                    artist,
                    channelId: channelId,
                    expectedInLibrary: false,
                    libraryViewModel: libraryViewModel
                )
            }
            DiagnosticsLogger.api.info("Unsubscribed from artist: \(artist.name)")
        } catch {
            if let libraryViewModel {
                self.addArtistToLibrary(artist, channelId: channelId, libraryViewModel: libraryViewModel)
                libraryViewModel.markNeedsReloadOnActivation()
            }
            DiagnosticsLogger.api.error("Failed to unsubscribe from artist: \(error.localizedDescription)")
            throw error
        }
    }

    fileprivate static func invalidateLibraryResponseCaches() {
        // Library mutations can leave stale data in both the app-level cache and URL loading cache.
        APICache.shared.invalidate(matching: "browse:")
        APICache.shared.invalidate(matching: "playlist/get_add_to_playlist:")
        URLCache.shared.removeAllCachedResponses()
    }

    // MARK: - Queue Actions

    /// Adds a song to play next (immediately after current track).
    static func addToQueueNext(_ song: Song, playerService: PlayerService) {
        playerService.insertNextInQueue([song])
        DiagnosticsLogger.ui.info("Added song to play next: \(song.title)")
    }

    /// Adds a song to the end of the queue.
    static func addToQueueLast(_ song: Song, playerService: PlayerService) {
        playerService.appendToQueue([song])
        DiagnosticsLogger.ui.info("Added song to end of queue: \(song.title)")
    }

    /// Adds multiple songs (e.g., from an album) to play next.
    /// - Parameters:
    ///   - fallbackArtist: Artist name to use when songs have empty artists (e.g., album author)
    ///   - fallbackAlbum: Album info to use when songs don't have album metadata (e.g., album title/cover)
    static func addSongsToQueueNext(
        _ songs: [Song],
        playerService: PlayerService,
        fallbackArtist: String? = nil,
        fallbackAlbum: Album? = nil
    ) {
        guard !songs.isEmpty else { return }

        // Clean artists and use fallback when empty
        let cleanedSongs = songs.map { song in
            var cleanedArtists = song.artists.compactMap(Self.cleanedArtistPreservingMetadata)

            // Use fallback artist if artists are empty (and clean the fallback too)
            if cleanedArtists.isEmpty, let fallback = fallbackArtist, !fallback.isEmpty {
                // Clean the fallback string - it might have "Album, " prefix or be "Album"
                var cleanFallback = fallback
                if cleanFallback == "Album" {
                    cleanFallback = "Unknown Artist"
                } else if cleanFallback.hasPrefix("Album, ") {
                    cleanFallback = String(cleanFallback.dropFirst(7))
                }
                // Also handle case where it's "Album, Artist" but we got it as a combined string
                if cleanFallback.contains("Album,") {
                    // Try to extract just the artist part after "Album,"
                    let parts = cleanFallback.split(separator: ",", maxSplits: 1)
                    if parts.count > 1 {
                        cleanFallback = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    }
                }
                cleanedArtists = [Artist(id: "unknown", name: cleanFallback)]
            }

            // Use fallback album if song doesn't have album info
            let finalAlbum = song.album ?? fallbackAlbum
            // Use fallback thumbnail if song doesn't have one
            let finalThumbnail = song.thumbnailURL ?? fallbackAlbum?.thumbnailURL

            return Song(
                id: song.id,
                title: song.title,
                artists: cleanedArtists,
                album: finalAlbum,
                duration: song.duration,
                thumbnailURL: finalThumbnail,
                videoId: song.videoId
            )
        }

        playerService.insertNextInQueue(cleanedSongs)
        DiagnosticsLogger.ui.info("Added \(cleanedSongs.count) songs to play next")
    }

    /// Adds multiple songs (e.g., from an album) to the end of the queue.
    /// - Parameters:
    ///   - fallbackArtist: Artist name to use when songs have empty artists (e.g., album author)
    ///   - fallbackAlbum: Album info to use when songs don't have album metadata (e.g., album title/cover)
    static func addSongsToQueueLast(
        _ songs: [Song],
        playerService: PlayerService,
        fallbackArtist: String? = nil,
        fallbackAlbum: Album? = nil
    ) {
        guard !songs.isEmpty else { return }

        // Clean artists and use fallback when empty
        let cleanedSongs = songs.map { song in
            var cleanedArtists = song.artists.compactMap(Self.cleanedArtistPreservingMetadata)

            // Use fallback artist if artists are empty (and clean the fallback too)
            if cleanedArtists.isEmpty, let fallback = fallbackArtist, !fallback.isEmpty {
                // Clean the fallback string - it might have "Album, " prefix or be "Album"
                var cleanFallback = fallback
                if cleanFallback == "Album" {
                    cleanFallback = "Unknown Artist"
                } else if cleanFallback.hasPrefix("Album, ") {
                    cleanFallback = String(cleanFallback.dropFirst(7))
                }
                // Also handle case where it's "Album, Artist" but we got it as a combined string
                if cleanFallback.contains("Album,") {
                    // Try to extract just the artist part after "Album,"
                    let parts = cleanFallback.split(separator: ",", maxSplits: 1)
                    if parts.count > 1 {
                        cleanFallback = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    }
                }
                cleanedArtists = [Artist(id: "unknown", name: cleanFallback)]
            }

            // Use fallback album if song doesn't have album info
            let finalAlbum = song.album ?? fallbackAlbum
            // Use fallback thumbnail if song doesn't have one
            let finalThumbnail = song.thumbnailURL ?? fallbackAlbum?.thumbnailURL

            return Song(
                id: song.id,
                title: song.title,
                artists: cleanedArtists,
                album: finalAlbum,
                duration: song.duration,
                thumbnailURL: finalThumbnail,
                videoId: song.videoId
            )
        }

        playerService.appendToQueue(cleanedSongs)
        DiagnosticsLogger.ui.info("Added \(cleanedSongs.count) songs to end of queue")
    }

    // MARK: - Album Queue Actions

    /// Adds an album's songs to play next (immediately after current track).
    static func addAlbumToQueueNext(
        _ album: Album,
        client: any YTMusicClientProtocol,
        playerService: PlayerService
    ) {
        Task {
            do {
                // Fetch album tracks - albums are treated as playlists
                let response = try await client.getPlaylist(id: album.id)
                var songs = response.detail.tracks

                guard !songs.isEmpty else { return }

                // Clean up album artists - filter out "Album" keyword and clean names
                let cleanAlbumArtists = (album.artists ?? []).compactMap(Self.cleanedArtistPreservingMetadata)

                // Populate album and artist info for each song
                songs = songs.map { song in
                    // Use song artists if available and not empty, otherwise use cleaned album artists
                    let baseArtists = !song.artists.isEmpty ? song.artists : cleanAlbumArtists

                    // Also clean song artists - filter "Album" keyword and clean names
                    let effectiveArtists = baseArtists.compactMap(Self.cleanedArtistPreservingMetadata)

                    // Create updated song with album info and proper artists
                    return Song(
                        id: song.id,
                        title: song.title,
                        artists: effectiveArtists,
                        album: Album(
                            id: album.id,
                            title: album.title,
                            artists: cleanAlbumArtists,
                            thumbnailURL: album.thumbnailURL,
                            year: nil,
                            trackCount: album.trackCount
                        ),
                        duration: song.duration,
                        thumbnailURL: song.thumbnailURL ?? album.thumbnailURL,
                        videoId: song.videoId
                    )
                }

                playerService.insertNextInQueue(songs)
                DiagnosticsLogger.ui.info("Added album '\(album.title)' (\(songs.count) songs) to play next")
            } catch {
                DiagnosticsLogger.ui.error("Failed to add album to queue: \(error.localizedDescription)")
            }
        }
    }

    /// Adds an album's songs to the end of the queue.
    static func addAlbumToQueueLast(
        _ album: Album,
        client: any YTMusicClientProtocol,
        playerService: PlayerService
    ) {
        Task {
            do {
                // Fetch album tracks - albums are treated as playlists
                let response = try await client.getPlaylist(id: album.id)
                var songs = response.detail.tracks

                guard !songs.isEmpty else { return }

                // Clean up album artists - filter out "Album" keyword and clean names
                let cleanAlbumArtists = (album.artists ?? []).compactMap(Self.cleanedArtistPreservingMetadata)

                // Populate album and artist info for each song
                songs = songs.map { song in
                    // Use song artists if available and not empty, otherwise use cleaned album artists
                    let baseArtists = !song.artists.isEmpty ? song.artists : cleanAlbumArtists

                    // Also clean song artists - filter "Album" keyword and clean names
                    let effectiveArtists = baseArtists.compactMap(Self.cleanedArtistPreservingMetadata)

                    // Create updated song with album info and proper artists
                    return Song(
                        id: song.id,
                        title: song.title,
                        artists: effectiveArtists,
                        album: Album(
                            id: album.id,
                            title: album.title,
                            artists: cleanAlbumArtists,
                            thumbnailURL: album.thumbnailURL,
                            year: nil,
                            trackCount: album.trackCount
                        ),
                        duration: song.duration,
                        thumbnailURL: song.thumbnailURL ?? album.thumbnailURL,
                        videoId: song.videoId
                    )
                }

                playerService.appendToQueue(songs)
                DiagnosticsLogger.ui.info("Added album '\(album.title)' (\(songs.count) songs) to end of queue")
            } catch {
                DiagnosticsLogger.ui.error("Failed to add album to queue: \(error.localizedDescription)")
            }
        }
    }

    /// Plays an album immediately, replacing the current queue.
    static func playAlbum(
        _ album: Album,
        client: any YTMusicClientProtocol,
        playerService: PlayerService
    ) {
        Task {
            do {
                // Fetch album tracks - albums are treated as playlists
                let response = try await client.getPlaylist(id: album.id)
                var songs = response.detail.tracks

                guard !songs.isEmpty else { return }

                // Clean up album artists - filter out "Album" keyword and clean names
                let cleanAlbumArtists = (album.artists ?? []).compactMap(Self.cleanedArtistPreservingMetadata)

                // Populate album and artist info for each song
                songs = songs.map { song in
                    // Use song artists if available and not empty, otherwise use cleaned album artists
                    let baseArtists = !song.artists.isEmpty ? song.artists : cleanAlbumArtists

                    // Also clean song artists - filter "Album" keyword and clean names
                    let effectiveArtists = baseArtists.compactMap(Self.cleanedArtistPreservingMetadata)

                    // Create album object for the song
                    let songAlbum = Album(
                        id: album.id,
                        title: album.title,
                        artists: cleanAlbumArtists.isEmpty ? nil : cleanAlbumArtists,
                        thumbnailURL: album.thumbnailURL,
                        year: album.year,
                        trackCount: songs.count
                    )

                    // Create updated song with album info and proper artists
                    return Song(
                        id: song.id,
                        title: song.title,
                        artists: effectiveArtists.isEmpty ? cleanAlbumArtists : effectiveArtists,
                        album: songAlbum,
                        duration: song.duration,
                        thumbnailURL: song.thumbnailURL ?? album.thumbnailURL,
                        videoId: song.videoId
                    )
                }

                // Stop current playback and play the album
                await playerService.playQueue(songs, startingAt: 0)
                DiagnosticsLogger.ui.info("Playing album '\(album.title)' (\(songs.count) songs)")
            } catch {
                DiagnosticsLogger.ui.error("Failed to play album: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - LikeDislikeContextMenu

/// Reusable context menu items for like/dislike actions.
@available(macOS 26.0, *)
struct LikeDislikeContextMenu: View {
    let song: Song
    let likeStatusManager: SongLikeStatusManager

    var body: some View {
        // Show Unlike if already liked, otherwise show Like
        if self.likeStatusManager.isLiked(self.song) {
            Button {
                SongActionsHelper.unlikeSong(self.song, likeStatusManager: self.likeStatusManager)
            } label: {
                Label("Unlike", systemImage: "hand.thumbsup.fill")
            }
        } else {
            Button {
                SongActionsHelper.likeSong(self.song, likeStatusManager: self.likeStatusManager)
            } label: {
                Label("Like", systemImage: "hand.thumbsup")
            }

            // Only show Dislike if not already liked
            if self.likeStatusManager.isDisliked(self.song) {
                Button {
                    SongActionsHelper.undislikeSong(self.song, likeStatusManager: self.likeStatusManager)
                } label: {
                    Label("Remove Dislike", systemImage: "hand.thumbsdown.fill")
                }
            } else {
                Button {
                    SongActionsHelper.dislikeSong(self.song, likeStatusManager: self.likeStatusManager)
                } label: {
                    Label("Dislike", systemImage: "hand.thumbsdown")
                }
            }
        }
    }
}

// MARK: - AddToQueueContextMenu

/// Reusable context menu items for adding songs to the queue.
@available(macOS 26.0, *)
struct AddToQueueContextMenu: View {
    let song: Song
    let playerService: PlayerService

    var body: some View {
        Button {
            SongActionsHelper.addToQueueNext(self.song, playerService: self.playerService)
        } label: {
            Label("Play Next", systemImage: "text.insert")
        }

        Button {
            SongActionsHelper.addToQueueLast(self.song, playerService: self.playerService)
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }
    }
}

// MARK: - AddToPlaylistContextMenu

/// Reusable context-menu submenu for adding a song to one of the user's playlists.
@available(macOS 26.0, *)
struct AddToPlaylistContextMenu: View {
    let song: Song
    let client: any YTMusicClientProtocol

    @Environment(LibraryViewModel.self) private var libraryViewModel: LibraryViewModel?

    @State private var loadState: PlaylistLoadState = .idle
    @State private var isCreatingPlaylist = false

    private static let playlistLoadTimeout: Duration = .seconds(12)

    private enum PlaylistLoadError: Error {
        case timedOut
    }

    private enum PlaylistLoadState {
        case idle
        case loading
        case loaded(AddToPlaylistMenu)
        case failed(String)
    }

    var body: some View {
        Menu {
            Group {
                switch self.loadState {
                case .idle, .loading:
                    Label("Loading Playlists…", systemImage: "hourglass")

                case let .loaded(menu):
                    if menu.options.isEmpty {
                        Label("No Playlists", systemImage: "music.note.list")
                    } else {
                        ForEach(menu.options) { option in
                            Button {
                                Task {
                                    await SongActionsHelper.addSongToPlaylist(
                                        self.song,
                                        playlist: option,
                                        client: self.client
                                    )
                                }
                            } label: {
                                Label(
                                    option.title,
                                    systemImage: option.isSelected ? "checkmark.circle.fill" : "music.note.list"
                                )
                            }
                            .disabled(option.isSelected)
                        }
                    }

                case let .failed(errorMessage):
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                    Button {
                        Task { await self.loadPlaylists(forceRefresh: true) }
                    } label: {
                        Label("Retry Loading Playlists", systemImage: "arrow.clockwise")
                    }
                }

                if self.canCreatePlaylist {
                    Divider()
                    self.createPlaylistButton
                }
            }
            .onAppear {
                self.startLoadingPlaylistsIfNeeded()
            }
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }
        .onAppear {
            // Start loading as soon as the parent context menu is built, not only
            // after the submenu opens. AppKit/SwiftUI menu contents are largely
            // snapshotted while open, so preloading prevents the submenu from
            // sitting on a stale "Loading Playlists…" row until the user closes
            // and reopens it.
            self.startLoadingPlaylistsIfNeeded()
        }
    }

    private var canCreatePlaylist: Bool {
        guard case let .loaded(menu) = self.loadState else { return false }
        return menu.canCreatePlaylist
    }

    private var createPlaylistButton: some View {
        Button {
            Task { @MainActor in self.presentCreatePlaylistDialog() }
        } label: {
            Label(self.isCreatingPlaylist ? "Creating Playlist…" : "Create Playlist…", systemImage: "plus.rectangle.on.rectangle")
        }
        .disabled(self.isCreatingPlaylist)
    }

    private func startLoadingPlaylistsIfNeeded() {
        guard case .idle = self.loadState else { return }

        Task { await self.loadPlaylists(forceRefresh: false) }
    }

    private func loadPlaylists(forceRefresh: Bool = false) async {
        guard !Task.isCancelled else { return }
        self.loadState = .loading
        if forceRefresh {
            APICache.shared.invalidate(matching: "playlist/get_add_to_playlist:")
        }

        do {
            let menu = try await self.fetchAddToPlaylistOptionsWithTimeout()
            self.loadState = .loaded(menu)
        } catch is CancellationError {
            // Opening and closing menus can cancel view-scoped work. Keep the
            // submenu in the non-failed initial state so the next open retries
            // automatically instead of showing a manual retry before a real
            // request failure has occurred.
            self.loadState = .idle
        } catch {
            self.loadState = .failed("Unable to Load Playlists")
            DiagnosticsLogger.ui.error("Failed to load add-to-playlist options: \(error.localizedDescription)")
        }
    }

    private func fetchAddToPlaylistOptionsWithTimeout() async throws -> AddToPlaylistMenu {
        let client = self.client
        let videoId = self.song.videoId

        return try await withThrowingTaskGroup(of: AddToPlaylistMenu.self) { group in
            group.addTask {
                try await client.getAddToPlaylistOptions(videoId: videoId)
            }

            group.addTask {
                try await Task.sleep(for: Self.playlistLoadTimeout)
                throw PlaylistLoadError.timedOut
            }

            defer { group.cancelAll() }

            guard let result = try await group.next() else {
                throw CancellationError()
            }

            return result
        }
    }

    private func presentCreatePlaylistDialog() {
        guard !self.isCreatingPlaylist else { return }

        let alert = NSAlert()
        alert.messageText = "Create Playlist"
        alert.informativeText = "Create a private playlist and add \"\(self.song.title)\" to it."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let titleField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        titleField.placeholderString = "Playlist name"
        alert.accessoryView = titleField
        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                self.loadState = .failed("Playlist Name Required")
                return
            }
            Task { await self.createPlaylist(title: title) }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }

    private func createPlaylist(title: String) async {
        guard !title.isEmpty, !self.isCreatingPlaylist else { return }
        self.isCreatingPlaylist = true
        defer { self.isCreatingPlaylist = false }
        do {
            let playlistId = try await self.client.createPlaylist(
                title: title,
                description: nil,
                privacyStatus: .private,
                videoIds: [self.song.videoId]
            )
            SongActionsHelper.invalidateLibraryResponseCaches()
            if let libraryViewModel {
                let playlist = Playlist(
                    id: playlistId,
                    title: title,
                    description: nil,
                    thumbnailURL: self.song.thumbnailURL,
                    trackCount: 1
                )
                libraryViewModel.markNeedsReloadOnActivation()
                libraryViewModel.addToLibrary(playlist: playlist)
                // Library browse responses can lag briefly behind a successful playlist creation.
                try? await Task.sleep(for: .milliseconds(500))
                await libraryViewModel.refresh()
                SongActionsHelper.invalidateLibraryResponseCaches()
                if !libraryViewModel.isInLibrary(playlistId: playlistId) {
                    libraryViewModel.addToLibrary(playlist: playlist)
                    SongActionsHelper.invalidateLibraryResponseCaches()
                }
            }
            await self.loadPlaylists(forceRefresh: true)
        } catch {
            self.loadState = .failed("Unable to Create Playlist")
            DiagnosticsLogger.ui.error("Failed to create playlist: \(error.localizedDescription)")
        }
    }
}
