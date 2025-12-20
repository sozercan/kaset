import Foundation
import Observation
import os

/// View model for the Library view.
@MainActor
@Observable
final class LibraryViewModel {
    /// Loading states for the view.
    enum LoadingState: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// User's playlists.
    private(set) var playlists: [Playlist] = []

    /// Selected playlist detail.
    private(set) var selectedPlaylistDetail: PlaylistDetail?

    /// Loading state for playlist detail.
    private(set) var playlistDetailLoadingState: LoadingState = .idle

    /// The API client (exposed for navigation to detail views).
    let client: YTMusicClient
    private let logger = DiagnosticsLogger.api

    init(client: YTMusicClient) {
        self.client = client
    }

    /// Loads library playlists.
    func load() async {
        guard loadingState != .loading else { return }

        loadingState = .loading
        logger.info("Loading library playlists")

        do {
            let loadedPlaylists = try await client.getLibraryPlaylists()
            playlists = loadedPlaylists
            loadingState = .loaded
            logger.info("Loaded \(loadedPlaylists.count) playlists")
        } catch {
            logger.error("Failed to load library: \(error.localizedDescription)")
            loadingState = .error(error.localizedDescription)
        }
    }

    /// Loads a specific playlist's details.
    func loadPlaylist(id: String) async {
        guard playlistDetailLoadingState != .loading else { return }

        playlistDetailLoadingState = .loading
        logger.info("Loading playlist: \(id)")

        do {
            let detail = try await client.getPlaylist(id: id)
            selectedPlaylistDetail = detail
            playlistDetailLoadingState = .loaded
            let trackCount = detail.tracks.count
            logger.info("Loaded playlist with \(trackCount) tracks")
        } catch {
            logger.error("Failed to load playlist: \(error.localizedDescription)")
            playlistDetailLoadingState = .error(error.localizedDescription)
        }
    }

    /// Clears the selected playlist.
    func clearSelectedPlaylist() {
        selectedPlaylistDetail = nil
        playlistDetailLoadingState = .idle
    }

    /// Refreshes library content.
    func refresh() async {
        playlists = []
        await load()
    }
}
