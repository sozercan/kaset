import Foundation
import Observation
import os

/// View model for the Library view.
@MainActor
@Observable
final class LibraryViewModel {
    /// Shared instance for checking library status from other views.
    static var shared: LibraryViewModel?

    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// User's playlists.
    private(set) var playlists: [Playlist] = []

    /// Set of playlist IDs that are in the user's library (for quick lookup).
    private(set) var libraryPlaylistIds: Set<String> = []

    /// Selected playlist detail.
    private(set) var selectedPlaylistDetail: PlaylistDetail?

    /// Loading state for playlist detail.
    private(set) var playlistDetailLoadingState: LoadingState = .idle

    /// The API client (exposed for navigation to detail views).
    let client: any YTMusicClientProtocol
    private let logger = DiagnosticsLogger.api

    init(client: any YTMusicClientProtocol) {
        self.client = client
        // Set shared instance for global access
        LibraryViewModel.shared = self
    }

    /// Checks if a playlist is in the user's library.
    func isInLibrary(playlistId: String) -> Bool {
        // Normalize the ID for comparison (remove VL prefix if present)
        let normalizedId = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        return self.libraryPlaylistIds.contains { storedId in
            let normalizedStoredId = storedId.hasPrefix("VL") ? String(storedId.dropFirst(2)) : storedId
            return normalizedId == normalizedStoredId || playlistId == storedId
        }
    }

    /// Adds a playlist ID to the library set (called after successful add to library).
    func addToLibrarySet(playlistId: String) {
        self.libraryPlaylistIds.insert(playlistId)
    }

    /// Removes a playlist ID from the library set (called after successful remove from library).
    func removeFromLibrarySet(playlistId: String) {
        // Remove both the exact ID and normalized versions
        self.libraryPlaylistIds.remove(playlistId)
        let normalizedId = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        self.libraryPlaylistIds = self.libraryPlaylistIds.filter { storedId in
            let normalizedStoredId = storedId.hasPrefix("VL") ? String(storedId.dropFirst(2)) : storedId
            return normalizedId != normalizedStoredId
        }
    }

    /// Loads library playlists.
    func load() async {
        guard self.loadingState != .loading else { return }

        self.loadingState = .loading
        self.logger.info("Loading library playlists")

        do {
            let loadedPlaylists = try await client.getLibraryPlaylists()
            self.playlists = loadedPlaylists
            // Update the set of library playlist IDs for quick lookup
            self.libraryPlaylistIds = Set(loadedPlaylists.map(\.id))
            self.loadingState = .loaded
            self.logger.info("Loaded \(loadedPlaylists.count) playlists")
        } catch is CancellationError {
            // Task was cancelled (e.g., user navigated away) — reset to idle so it can retry
            self.logger.debug("Library load cancelled")
            self.loadingState = .idle
        } catch {
            self.logger.error("Failed to load library: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    /// Loads a specific playlist's details.
    func loadPlaylist(id: String) async {
        guard self.playlistDetailLoadingState != .loading else { return }

        self.playlistDetailLoadingState = .loading
        self.logger.info("Loading playlist: \(id)")

        do {
            let response = try await client.getPlaylist(id: id)
            self.selectedPlaylistDetail = response.detail
            self.playlistDetailLoadingState = .loaded
            let trackCount = response.detail.tracks.count
            self.logger.info("Loaded playlist with \(trackCount) tracks")
        } catch is CancellationError {
            // Task was cancelled (e.g., user navigated away) — reset to idle so it can retry
            self.logger.debug("Playlist load cancelled")
            self.playlistDetailLoadingState = .idle
        } catch {
            self.logger.error("Failed to load playlist: \(error.localizedDescription)")
            self.playlistDetailLoadingState = .error(LoadingError(from: error))
        }
    }

    /// Clears the selected playlist.
    func clearSelectedPlaylist() {
        self.selectedPlaylistDetail = nil
        self.playlistDetailLoadingState = .idle
    }

    /// Refreshes library content.
    func refresh() async {
        self.playlists = []
        await self.load()
    }
}
