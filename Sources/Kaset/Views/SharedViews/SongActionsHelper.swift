import Foundation
import SwiftUI

// MARK: - SongActionsHelper

/// Helper for common song actions like liking, disliking, adding to library, and queue management.
@MainActor
enum SongActionsHelper {
    static var artistLibraryReconciliationRetryDelays: [Duration] = [.seconds(2), .seconds(3)]

    private static var artistLibraryReconciliationTasks: [String: Task<Void, Never>] = [:]

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

    private static func invalidateLibraryResponseCaches() {
        // Library mutations can leave stale data in both the app-level cache and URL loading cache.
        APICache.shared.invalidate(matching: "browse:")
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
            var cleanedArtists = song.artists.compactMap { artist -> Artist? in
                if artist.name == "Album" { return nil }
                var cleanName = artist.name
                if cleanName.hasPrefix("Album, ") {
                    cleanName = String(cleanName.dropFirst(7))
                }
                return Artist(id: artist.id, name: cleanName)
            }

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
            var cleanedArtists = song.artists.compactMap { artist -> Artist? in
                if artist.name == "Album" { return nil }
                var cleanName = artist.name
                if cleanName.hasPrefix("Album, ") {
                    cleanName = String(cleanName.dropFirst(7))
                }
                return Artist(id: artist.id, name: cleanName)
            }

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
                let cleanAlbumArtists = (album.artists ?? []).compactMap { artist -> Artist? in
                    var cleanName = artist.name

                    // Skip artists that are literally just "Album" (the keyword, not an artist name)
                    if cleanName == "Album" {
                        return nil
                    }

                    // Also clean "Album, " prefix if present
                    if cleanName.hasPrefix("Album, ") {
                        cleanName = String(cleanName.dropFirst(7))
                    }

                    return Artist(id: artist.id, name: cleanName)
                }

                // Populate album and artist info for each song
                songs = songs.map { song in
                    // Use song artists if available and not empty, otherwise use cleaned album artists
                    let baseArtists = !song.artists.isEmpty ? song.artists : cleanAlbumArtists

                    // Also clean song artists - filter "Album" keyword and clean names
                    let effectiveArtists = baseArtists.compactMap { artist -> Artist? in
                        var cleanName = artist.name

                        // Skip artists that are literally just "Album"
                        if cleanName == "Album" {
                            return nil
                        }

                        // Clean "Album, " prefix if present
                        if cleanName.hasPrefix("Album, ") {
                            cleanName = String(cleanName.dropFirst(7))
                        }
                        return Artist(id: artist.id, name: cleanName)
                    }

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
                let cleanAlbumArtists = (album.artists ?? []).compactMap { artist -> Artist? in
                    var cleanName = artist.name

                    // Skip artists that are literally just "Album" (the keyword, not an artist name)
                    if cleanName == "Album" {
                        return nil
                    }

                    // Also clean "Album, " prefix if present
                    if cleanName.hasPrefix("Album, ") {
                        cleanName = String(cleanName.dropFirst(7))
                    }

                    return Artist(id: artist.id, name: cleanName)
                }

                // Populate album and artist info for each song
                songs = songs.map { song in
                    // Use song artists if available and not empty, otherwise use cleaned album artists
                    let baseArtists = !song.artists.isEmpty ? song.artists : cleanAlbumArtists

                    // Also clean song artists - filter "Album" keyword and clean names
                    let effectiveArtists = baseArtists.compactMap { artist -> Artist? in
                        var cleanName = artist.name

                        // Skip artists that are literally just "Album"
                        if cleanName == "Album" {
                            return nil
                        }

                        // Clean "Album, " prefix if present
                        if cleanName.hasPrefix("Album, ") {
                            cleanName = String(cleanName.dropFirst(7))
                        }
                        return Artist(id: artist.id, name: cleanName)
                    }

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
                let cleanAlbumArtists = (album.artists ?? []).compactMap { artist -> Artist? in
                    var cleanName = artist.name

                    // Skip artists that are literally just "Album" (the keyword, not an artist name)
                    if cleanName == "Album" {
                        return nil
                    }

                    // Also clean "Album, " prefix if present
                    if cleanName.hasPrefix("Album, ") {
                        cleanName = String(cleanName.dropFirst(7))
                    }

                    return Artist(id: artist.id, name: cleanName)
                }

                // Populate album and artist info for each song
                songs = songs.map { song in
                    // Use song artists if available and not empty, otherwise use cleaned album artists
                    let baseArtists = !song.artists.isEmpty ? song.artists : cleanAlbumArtists

                    // Also clean song artists - filter "Album" keyword and clean names
                    let effectiveArtists = baseArtists.compactMap { artist -> Artist? in
                        var cleanName = artist.name

                        // Skip artists that are literally just "Album"
                        if cleanName == "Album" {
                            return nil
                        }

                        // Clean "Album, " prefix if present
                        if cleanName.hasPrefix("Album, ") {
                            cleanName = String(cleanName.dropFirst(7))
                        }
                        return Artist(id: artist.id, name: cleanName)
                    }

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
