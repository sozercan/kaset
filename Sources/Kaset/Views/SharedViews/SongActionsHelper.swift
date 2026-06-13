import AppKit
import Foundation
import SwiftUI

// MARK: - SongActionsHelper

/// Helper for common song actions like liking, disliking, adding to library, and queue management.
@MainActor
enum SongActionsHelper {
    static var artistLibraryReconciliationRetryDelays: [Duration] {
        get { LibraryMutationActions.artistReconciliationRetryDelays }
        set { LibraryMutationActions.artistReconciliationRetryDelays = newValue }
    }

    /// Whether a playlist card should expose direct playback.
    static func canQuickPlayPlaylist(_ playlist: Playlist) -> Bool {
        !MoodCategory.isMoodCategory(playlist.id)
    }

    private static func isRadioPlaylist(_ playlistId: String) -> Bool {
        playlistId.contains("RDCLAK") || playlistId.hasPrefix("RD")
    }

    private static func tracksForPlaylistPlayback(browseTracks: [Song], queueTracks: [Song]) -> [Song] {
        var browsePlayabilityByVideoId: [String: Bool] = [:]
        for track in browseTracks {
            browsePlayabilityByVideoId[track.videoId] = track.isPlayable
        }

        return queueTracks.map { track in
            guard let browseIsPlayable = browsePlayabilityByVideoId[track.videoId],
                  browseIsPlayable != track.isPlayable
            else {
                return track
            }

            return Song(
                id: track.id,
                title: track.title,
                artists: track.artists,
                album: track.album,
                duration: track.duration,
                thumbnailURL: track.thumbnailURL,
                videoId: track.videoId,
                isPlayable: browseIsPlayable,
                hasVideo: track.hasVideo,
                musicVideoType: track.musicVideoType,
                likeStatus: track.likeStatus,
                isInLibrary: track.isInLibrary,
                feedbackTokens: track.feedbackTokens,
                isExplicit: track.isExplicit
            )
        }
    }

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
        await LibraryMutationActions.addSongToPlaylist(song, playlist: playlist, client: client)
    }

    /// Adds a playlist to the library.
    static func addPlaylistToLibrary(
        _ playlist: Playlist,
        client: any YTMusicClientProtocol,
        libraryViewModel: LibraryViewModel?
    ) async {
        await LibraryMutationActions.addPlaylistToLibrary(
            playlist,
            client: client,
            libraryViewModel: libraryViewModel
        )
    }

    /// Removes a playlist from the library.
    static func removePlaylistFromLibrary(
        _ playlist: Playlist,
        client: any YTMusicClientProtocol,
        libraryViewModel: LibraryViewModel?
    ) async {
        await LibraryMutationActions.removePlaylistFromLibrary(
            playlist,
            client: client,
            libraryViewModel: libraryViewModel
        )
    }

    /// Plays a playlist immediately, replacing the current queue.
    static func playPlaylist(
        _ playlist: Playlist,
        client: any YTMusicClientProtocol,
        playerService: PlayerService
    ) {
        Task {
            do {
                let response = try await client.getPlaylist(id: playlist.id)
                var songs = response.detail.tracks

                if self.isRadioPlaylist(playlist.id) {
                    do {
                        let allTracks = try await client.getPlaylistAllTracks(playlistId: playlist.id)
                        if allTracks.count >= songs.count, !allTracks.isEmpty {
                            songs = self.tracksForPlaylistPlayback(
                                browseTracks: response.detail.tracks,
                                queueTracks: allTracks
                            )
                        }
                    } catch {
                        DiagnosticsLogger.ui.debug("Falling back to browse playlist tracks: \(error.localizedDescription)")
                    }
                } else {
                    let playableSongs = PlaylistPlaybackHelper.playableSongsWithPlaylistArtwork(songs, playlist: playlist)
                    guard !playableSongs.isEmpty else { return }

                    await playerService.playQueue(playableSongs, startingAt: 0)
                    DiagnosticsLogger.ui.info("Playing playlist '\(playlist.title)' (\(playableSongs.count) initial songs)")

                    await PlaylistPlaybackHelper.appendContinuations(
                        PlaylistPlaybackHelper.ContinuationContext(
                            continuationToken: response.continuationToken,
                            existingVideoIds: Set(songs.map(\.videoId)),
                            expectedQueueEntryIDs: playerService.queueEntryIDs,
                            playlist: playlist,
                            client: client,
                            playerService: playerService
                        )
                    )
                    return
                }

                let playableSongs = PlaylistPlaybackHelper.playableSongsWithPlaylistArtwork(songs, playlist: playlist)
                guard !playableSongs.isEmpty else { return }

                await playerService.playQueue(playableSongs, startingAt: 0)
                DiagnosticsLogger.ui.info("Playing playlist '\(playlist.title)' (\(playableSongs.count) songs)")
            } catch {
                DiagnosticsLogger.ui.error("Failed to play playlist: \(error.localizedDescription)")
            }
        }
    }

    /// Permanently deletes a playlist owned by the user.
    static func deletePlaylist(
        _ playlist: Playlist,
        client: any YTMusicClientProtocol,
        libraryViewModel: LibraryViewModel?
    ) async throws {
        try await LibraryMutationActions.deletePlaylist(
            playlist,
            client: client,
            libraryViewModel: libraryViewModel
        )
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
        try await LibraryMutationActions.subscribeToPodcast(
            show,
            client: client,
            libraryViewModel: libraryViewModel
        )
    }

    /// Unsubscribes from a podcast show (removes from library).
    static func unsubscribeFromPodcast(
        _ show: PodcastShow,
        client: any YTMusicClientProtocol,
        libraryViewModel: LibraryViewModel?
    ) async throws {
        try await LibraryMutationActions.unsubscribeFromPodcast(
            show,
            client: client,
            libraryViewModel: libraryViewModel
        )
    }

    /// Subscribes to an artist (adds to library).
    static func subscribeToArtist(
        _ artist: Artist,
        channelId: String,
        client: any YTMusicClientProtocol,
        libraryViewModel: LibraryViewModel?
    ) async throws {
        try await LibraryMutationActions.subscribeToArtist(
            artist,
            channelId: channelId,
            client: client,
            libraryViewModel: libraryViewModel
        )
    }

    /// Unsubscribes from an artist (removes from library).
    static func unsubscribeFromArtist(
        _ artist: Artist,
        channelId: String,
        client: any YTMusicClientProtocol,
        libraryViewModel: LibraryViewModel?
    ) async throws {
        try await LibraryMutationActions.unsubscribeFromArtist(
            artist,
            channelId: channelId,
            client: client,
            libraryViewModel: libraryViewModel
        )
    }

    static func invalidateLibraryResponseCaches() {
        LibraryMutationActions.invalidateResponseCaches()
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

// MARK: - PlaylistPlaybackHelper

@MainActor
private enum PlaylistPlaybackHelper {
    struct ContinuationContext {
        let continuationToken: String?
        let existingVideoIds: Set<String>
        let expectedQueueEntryIDs: [UUID]
        let playlist: Playlist
        let client: any YTMusicClientProtocol
        let playerService: PlayerService
    }

    static func playableSongsWithPlaylistArtwork(_ songs: [Song], playlist: Playlist) -> [Song] {
        songs.filter(\.isPlayable).map { song in
            Song(
                id: song.id,
                title: song.title,
                artists: song.artists,
                album: song.album,
                duration: song.duration,
                thumbnailURL: song.thumbnailURL ?? playlist.thumbnailURL,
                videoId: song.videoId,
                isPlayable: song.isPlayable,
                hasVideo: song.hasVideo,
                musicVideoType: song.musicVideoType,
                likeStatus: song.likeStatus,
                isInLibrary: song.isInLibrary,
                feedbackTokens: song.feedbackTokens,
                isExplicit: song.isExplicit
            )
        }
    }

    static func appendContinuations(_ context: ContinuationContext) async {
        var nextContinuationToken = context.continuationToken
        var seenVideoIds = context.existingVideoIds

        while let token = nextContinuationToken, !Task.isCancelled {
            do {
                let response = try await context.client.getPlaylistContinuation(token: token)
                let newTracks = response.tracks.filter { seenVideoIds.insert($0.videoId).inserted }
                guard !newTracks.isEmpty else { break }

                let playableSongs = Self.playableSongsWithPlaylistArtwork(newTracks, playlist: context.playlist)
                if !playableSongs.isEmpty {
                    guard Array(context.playerService.queueEntryIDs.prefix(context.expectedQueueEntryIDs.count)) == context.expectedQueueEntryIDs else {
                        DiagnosticsLogger.ui.debug("Discarding playlist continuations because the queue changed")
                        return
                    }
                    context.playerService.appendToQueue(playableSongs)
                }

                nextContinuationToken = response.continuationToken
            } catch {
                DiagnosticsLogger.ui.debug("Stopped loading playlist continuations: \(error.localizedDescription)")
                break
            }
        }
    }
}
