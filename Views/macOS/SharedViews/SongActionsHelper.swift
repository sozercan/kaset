import Foundation

// MARK: - SongActionsHelper

/// Helper for common song actions like liking, disliking, and adding to library.
@MainActor
enum SongActionsHelper {
    /// Likes a song by playing it and then liking the current track.
    static func likeSong(_ song: Song, playerService: PlayerService) {
        Task {
            await playerService.play(song: song)
            try? await Task.sleep(for: .milliseconds(100))
            playerService.likeCurrentTrack()
        }
    }

    /// Dislikes a song by playing it and then disliking the current track.
    static func dislikeSong(_ song: Song, playerService: PlayerService) {
        Task {
            await playerService.play(song: song)
            try? await Task.sleep(for: .milliseconds(100))
            playerService.dislikeCurrentTrack()
        }
    }

    /// Adds a song to the library by playing it and toggling library status.
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
        client: any YTMusicClientProtocol
    ) async {
        do {
            try await client.subscribeToPlaylist(playlistId: playlist.id)
            LibraryViewModel.shared?.addToLibrarySet(playlistId: playlist.id)
            await LibraryViewModel.shared?.refresh()
            DiagnosticsLogger.api.info("Added playlist to library: \(playlist.title)")
        } catch {
            DiagnosticsLogger.api.error("Failed to add playlist to library: \(error.localizedDescription)")
        }
    }

    /// Removes a playlist from the library.
    static func removePlaylistFromLibrary(
        _ playlist: Playlist,
        client: any YTMusicClientProtocol
    ) async {
        do {
            try await client.unsubscribeFromPlaylist(playlistId: playlist.id)
            LibraryViewModel.shared?.removeFromLibrarySet(playlistId: playlist.id)
            await LibraryViewModel.shared?.refresh()
            DiagnosticsLogger.api.info("Removed playlist from library: \(playlist.title)")
        } catch {
            DiagnosticsLogger.api.error("Failed to remove playlist from library: \(error.localizedDescription)")
        }
    }
}
