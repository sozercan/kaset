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
    static func addSongsToQueueNext(_ songs: [Song], playerService: PlayerService) {
        guard !songs.isEmpty else { return }
        playerService.insertNextInQueue(songs)
        DiagnosticsLogger.ui.info("Added \(songs.count) songs to play next")
    }

    /// Adds multiple songs (e.g., from an album) to the end of the queue.
    static func addSongsToQueueLast(_ songs: [Song], playerService: PlayerService) {
        guard !songs.isEmpty else { return }
        playerService.appendToQueue(songs)
        DiagnosticsLogger.ui.info("Added \(songs.count) songs to end of queue")
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
            SongActionsHelper.addToQueueNext(song, playerService: playerService)
        } label: {
            Label("Play Next", systemImage: "text.insert")
        }

        Button {
            SongActionsHelper.addToQueueLast(song, playerService: playerService)
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }
    }
}
