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
        PlaylistPlaybackActions.playPlaylist(
            playlist,
            client: client,
            playerService: playerService
        )
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
        let preparedSongs = QueueSongMetadata.songsForQueue(
            songs,
            fallbackArtist: fallbackArtist,
            fallbackAlbum: fallbackAlbum
        )
        guard !preparedSongs.isEmpty else { return }

        playerService.insertNextInQueue(preparedSongs)
        DiagnosticsLogger.ui.info("Added \(preparedSongs.count) songs to play next")
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
        let preparedSongs = QueueSongMetadata.songsForQueue(
            songs,
            fallbackArtist: fallbackArtist,
            fallbackAlbum: fallbackAlbum
        )
        guard !preparedSongs.isEmpty else { return }

        playerService.appendToQueue(preparedSongs)
        DiagnosticsLogger.ui.info("Added \(preparedSongs.count) songs to end of queue")
    }

    // MARK: - Album Queue Actions

    /// Adds an album's songs to play next (immediately after current track).
    static func addAlbumToQueueNext(
        _ album: Album,
        client: any YTMusicClientProtocol,
        playerService: PlayerService
    ) {
        AlbumPlaybackActions.addAlbumToQueueNext(
            album,
            client: client,
            playerService: playerService
        )
    }

    /// Adds an album's songs to the end of the queue.
    static func addAlbumToQueueLast(
        _ album: Album,
        client: any YTMusicClientProtocol,
        playerService: PlayerService
    ) {
        AlbumPlaybackActions.addAlbumToQueueLast(
            album,
            client: client,
            playerService: playerService
        )
    }

    /// Plays an album immediately, replacing the current queue.
    static func playAlbum(
        _ album: Album,
        client: any YTMusicClientProtocol,
        playerService: PlayerService
    ) {
        AlbumPlaybackActions.playAlbum(
            album,
            client: client,
            playerService: playerService
        )
    }
}
