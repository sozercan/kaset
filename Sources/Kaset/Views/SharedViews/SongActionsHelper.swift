import Foundation
import SwiftUI

// MARK: - SongActionsHelper

/// Helper for common song actions like liking, disliking, adding to library, and queue management.
@MainActor
enum SongActionsHelper {
    /// Likes a song via the API (does not play the song).
    static func likeSong(_ song: Song, likeStatusManager: SongLikeStatusManager) {
        Task {
            await likeStatusManager.like(song)
        }
    }

    /// Unlikes a song (removes the like rating) via the API.
    static func unlikeSong(_ song: Song, likeStatusManager: SongLikeStatusManager) {
        Task {
            await likeStatusManager.unlike(song)
        }
    }

    /// Dislikes a song via the API (does not play the song).
    static func dislikeSong(_ song: Song, likeStatusManager: SongLikeStatusManager) {
        Task {
            await likeStatusManager.dislike(song)
        }
    }

    /// Undislikes a song (removes the dislike rating) via the API.
    static func undislikeSong(_ song: Song, likeStatusManager: SongLikeStatusManager) {
        Task {
            await likeStatusManager.undislike(song)
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
            libraryViewModel?.addToLibrarySet(playlistId: playlist.id)
            await libraryViewModel?.refresh()
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
            libraryViewModel?.removeFromLibrarySet(playlistId: playlist.id)
            await libraryViewModel?.refresh()
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
        libraryViewModel?.addToLibrarySet(podcastId: show.id)
        await libraryViewModel?.refresh()
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
        libraryViewModel?.removeFromLibrarySet(podcastId: show.id)
        await libraryViewModel?.refresh()
        DiagnosticsLogger.api.info("Unsubscribed from podcast: \(show.title)")
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
