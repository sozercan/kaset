import Foundation
import Observation
import os

/// View model for the PlaylistDetailView.
@MainActor
@Observable
final class PlaylistDetailViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// The loaded playlist detail.
    private(set) var playlistDetail: PlaylistDetail?

    private let playlist: Playlist
    /// The API client (exposed for add to library action).
    let client: any YTMusicClientProtocol
    private let logger = DiagnosticsLogger.api

    init(playlist: Playlist, client: any YTMusicClientProtocol) {
        self.playlist = playlist
        self.client = client
    }

    /// Loads the playlist details including tracks.
    func load() async {
        guard self.loadingState != .loading else { return }

        self.loadingState = .loading
        let playlistTitle = self.playlist.title
        self.logger.info("Loading playlist: \(playlistTitle)")

        do {
            var detail = try await client.getPlaylist(id: self.playlist.id)

            // Use original playlist info as fallback if API returned unknown/empty values
            if detail.title == "Unknown Playlist", self.playlist.title != "Unknown Playlist" {
                // Merge with original playlist info
                let mergedPlaylist = Playlist(
                    id: playlist.id,
                    title: self.playlist.title,
                    description: detail.description ?? self.playlist.description,
                    thumbnailURL: detail.thumbnailURL ?? self.playlist.thumbnailURL,
                    trackCount: detail.tracks.count,
                    author: detail.author ?? self.playlist.author
                )
                detail = PlaylistDetail(
                    playlist: mergedPlaylist,
                    tracks: detail.tracks,
                    duration: detail.duration
                )
            }

            self.playlistDetail = detail
            self.loadingState = .loaded
            let trackCount = detail.tracks.count
            self.logger.info("Playlist loaded: \(trackCount) tracks")
        } catch is CancellationError {
            // Task was cancelled (e.g., user navigated away) — reset to idle so it can retry
            self.logger.debug("Playlist detail load cancelled")
            self.loadingState = .idle
        } catch {
            let errorMessage = error.localizedDescription
            self.logger.error("Failed to load playlist: \(errorMessage)")
            self.loadingState = .error(errorMessage)
        }
    }

    /// Refreshes the playlist.
    func refresh() async {
        self.playlistDetail = nil
        await self.load()
    }
}
