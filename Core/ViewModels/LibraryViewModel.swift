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
        return libraryPlaylistIds.contains { storedId in
            let normalizedStoredId = storedId.hasPrefix("VL") ? String(storedId.dropFirst(2)) : storedId
            return normalizedId == normalizedStoredId || playlistId == storedId
        }
    }

    /// Adds a playlist ID to the library set (called after successful add to library).
    func addToLibrarySet(playlistId: String) {
        libraryPlaylistIds.insert(playlistId)
    }

    /// Removes a playlist ID from the library set (called after successful remove from library).
    func removeFromLibrarySet(playlistId: String) {
        // Remove both the exact ID and normalized versions
        libraryPlaylistIds.remove(playlistId)
        let normalizedId = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
        libraryPlaylistIds = libraryPlaylistIds.filter { storedId in
            let normalizedStoredId = storedId.hasPrefix("VL") ? String(storedId.dropFirst(2)) : storedId
            return normalizedId != normalizedStoredId
        }
    }

    /// Loads library playlists.
    func load() async {
        guard loadingState != .loading else { return }

        loadingState = .loading
        logger.info("Loading library playlists")

        do {
            let loadedPlaylists = try await client.getLibraryPlaylists()
            playlists = loadedPlaylists
            // Update the set of library playlist IDs for quick lookup
            libraryPlaylistIds = Set(loadedPlaylists.map(\.id))
            loadingState = .loaded
            logger.info("Loaded \(loadedPlaylists.count) playlists")
        } catch is CancellationError {
            // Task was cancelled (e.g., user navigated away) — reset to idle so it can retry
            logger.debug("Library load cancelled")
            loadingState = .idle
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
        } catch is CancellationError {
            // Task was cancelled (e.g., user navigated away) — reset to idle so it can retry
            logger.debug("Playlist load cancelled")
            playlistDetailLoadingState = .idle
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
