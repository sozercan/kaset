import Foundation
import Observation
import os

/// View model for the PlaylistDetailView.
@MainActor
@Observable
final class PlaylistDetailViewModel {
    /// Loading states for the view.
    enum LoadingState: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// The loaded playlist detail.
    private(set) var playlistDetail: PlaylistDetail?

    private let playlist: Playlist
    private let client: YTMusicClient
    private let logger = DiagnosticsLogger.api

    init(playlist: Playlist, client: YTMusicClient) {
        self.playlist = playlist
        self.client = client
    }

    /// Loads the playlist details including tracks.
    func load() async {
        guard loadingState != .loading else { return }

        loadingState = .loading
        let playlistTitle = playlist.title
        logger.info("Loading playlist: \(playlistTitle)")

        do {
            var detail = try await client.getPlaylist(id: playlist.id)

            // Use original playlist info as fallback if API returned unknown/empty values
            if detail.title == "Unknown Playlist", playlist.title != "Unknown Playlist" {
                // Merge with original playlist info
                let mergedPlaylist = Playlist(
                    id: playlist.id,
                    title: playlist.title,
                    description: detail.description ?? playlist.description,
                    thumbnailURL: detail.thumbnailURL ?? playlist.thumbnailURL,
                    trackCount: detail.tracks.count,
                    author: detail.author ?? playlist.author
                )
                detail = PlaylistDetail(
                    playlist: mergedPlaylist,
                    tracks: detail.tracks,
                    duration: detail.duration
                )
            }

            playlistDetail = detail
            loadingState = .loaded
            let trackCount = detail.tracks.count
            logger.info("Playlist loaded: \(trackCount) tracks")
        } catch {
            let errorMessage = error.localizedDescription
            logger.error("Failed to load playlist: \(errorMessage)")
            loadingState = .error(errorMessage)
        }
    }

    /// Refreshes the playlist.
    func refresh() async {
        playlistDetail = nil
        await load()
    }
}
