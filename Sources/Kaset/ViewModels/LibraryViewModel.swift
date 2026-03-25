import Foundation
import Observation
import os

/// View model for the Library view.
@MainActor
@Observable
final class LibraryViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// User's playlists.
    private(set) var playlists: [Playlist] = []

    /// User's followed artists.
    private(set) var artists: [Artist] = []

    /// User's subscribed podcast shows.
    private(set) var podcastShows: [PodcastShow] = []

    /// Set of playlist IDs that are in the user's library (for quick lookup).
    private(set) var libraryPlaylistIds: Set<String> = []

    /// Set of podcast show IDs that are in the user's library (for quick lookup).
    private(set) var libraryPodcastIds: Set<String> = []

    /// Set of followed artist IDs normalized to channel IDs (for quick lookup).
    private(set) var libraryArtistIds: Set<String> = []

    /// Selected playlist detail.
    private(set) var selectedPlaylistDetail: PlaylistDetail?

    /// Loading state for playlist detail.
    private(set) var playlistDetailLoadingState: LoadingState = .idle

    /// The API client (exposed for navigation to detail views).
    let client: any YTMusicClientProtocol
    private let logger = DiagnosticsLogger.api

    init(client: any YTMusicClientProtocol) {
        self.client = client
    }

    private static func normalizedPlaylistId(_ playlistId: String) -> String {
        if playlistId.hasPrefix("VL") {
            return String(playlistId.dropFirst(2))
        }
        return playlistId
    }

    private static func normalizedArtistId(_ artistId: String) -> String {
        if Artist.isLibraryArtistBrowseId(artistId) {
            return String(artistId.dropFirst("MPLA".count))
        }
        return artistId
    }

    /// Checks if a playlist is in the user's library.
    func isInLibrary(playlistId: String) -> Bool {
        let normalizedId = Self.normalizedPlaylistId(playlistId)
        return self.libraryPlaylistIds.contains { storedId in
            let normalizedStoredId = Self.normalizedPlaylistId(storedId)
            return normalizedId == normalizedStoredId || playlistId == storedId
        }
    }

    /// Checks if a podcast show is in the user's library.
    func isInLibrary(podcastId: String) -> Bool {
        self.libraryPodcastIds.contains(podcastId)
    }

    /// Checks if an artist is in the user's library.
    func isInLibrary(artistId: String) -> Bool {
        self.libraryArtistIds.contains(Self.normalizedArtistId(artistId))
    }

    /// Adds a playlist ID to the library set (called after successful add to library).
    func addToLibrarySet(playlistId: String) {
        self.libraryPlaylistIds.insert(playlistId)
    }

    /// Adds a playlist to the library (called after successful add to library).
    /// Updates both the ID set and the playlists array for immediate UI update.
    func addToLibrary(playlist: Playlist) {
        self.libraryPlaylistIds.insert(playlist.id)
        let normalizedPlaylistId = Self.normalizedPlaylistId(playlist.id)
        if !self.playlists.contains(where: { Self.normalizedPlaylistId($0.id) == normalizedPlaylistId }) {
            self.playlists.insert(playlist, at: 0)
        }
    }

    /// Adds a podcast to the library (called after successful subscription).
    /// Updates both the ID set and the shows array for immediate UI update.
    func addToLibrary(podcast: PodcastShow) {
        self.libraryPodcastIds.insert(podcast.id)
        // Add to shows array if not already present
        if !self.podcastShows.contains(where: { $0.id == podcast.id }) {
            self.podcastShows.insert(podcast, at: 0)
        }
    }

    /// Adds a podcast ID to the library set (called after successful subscription).
    func addToLibrarySet(podcastId: String) {
        self.libraryPodcastIds.insert(podcastId)
    }

    /// Adds an artist to the library (called after successful subscription).
    /// Updates both the ID set and the artists array for immediate UI update.
    func addToLibrary(artist: Artist, libraryArtistId: String? = nil) {
        let normalizedArtistId = Self.normalizedArtistId(libraryArtistId ?? artist.id)
        self.libraryArtistIds.insert(normalizedArtistId)
        if !self.artists.contains(where: { Self.normalizedArtistId($0.id) == normalizedArtistId }) {
            self.artists.insert(artist, at: 0)
        }
    }

    /// Adds an artist ID to the library set (called after successful subscription).
    func addToLibrarySet(artistId: String) {
        self.libraryArtistIds.insert(Self.normalizedArtistId(artistId))
    }

    /// Removes a playlist ID from the library set (called after successful remove from library).
    func removeFromLibrarySet(playlistId: String) {
        // Remove both the exact ID and normalized versions
        self.libraryPlaylistIds.remove(playlistId)
        let normalizedId = Self.normalizedPlaylistId(playlistId)
        self.libraryPlaylistIds = self.libraryPlaylistIds.filter { storedId in
            let normalizedStoredId = Self.normalizedPlaylistId(storedId)
            return normalizedId != normalizedStoredId
        }
    }

    /// Removes a playlist from the library (called after successful remove from library).
    /// Updates both the ID set and the playlists array for immediate UI update.
    func removeFromLibrary(playlistId: String) {
        self.removeFromLibrarySet(playlistId: playlistId)
        let normalizedPlaylistId = Self.normalizedPlaylistId(playlistId)
        self.playlists.removeAll { Self.normalizedPlaylistId($0.id) == normalizedPlaylistId }
    }

    /// Removes a podcast from the library (called after successful unsubscribe).
    /// Updates both the ID set and the shows array for immediate UI update.
    func removeFromLibrary(podcastId: String) {
        self.libraryPodcastIds.remove(podcastId)
        self.podcastShows.removeAll { $0.id == podcastId }
    }

    /// Removes a podcast ID from the library set (called after successful unsubscribe).
    func removeFromLibrarySet(podcastId: String) {
        self.libraryPodcastIds.remove(podcastId)
    }

    /// Removes an artist from the library (called after successful unsubscribe).
    /// Updates both the ID set and the artists array for immediate UI update.
    func removeFromLibrary(artistId: String) {
        let normalizedArtistId = Self.normalizedArtistId(artistId)
        self.libraryArtistIds.remove(normalizedArtistId)
        self.artists.removeAll { Self.normalizedArtistId($0.id) == normalizedArtistId }
    }

    /// Removes an artist ID from the library set (called after successful unsubscribe).
    func removeFromLibrarySet(artistId: String) {
        self.libraryArtistIds.remove(Self.normalizedArtistId(artistId))
    }

    /// Loads library content (playlists, artists, and podcasts).
    func load() async {
        guard self.loadingState != .loading else { return }

        self.loadingState = .loading
        self.logger.info("Loading library content")

        do {
            let content = try await client.getLibraryContent()
            self.playlists = content.playlists
            self.artists = content.artists
            self.podcastShows = content.podcastShows
            // Update the sets for quick lookup
            self.libraryPlaylistIds = Set(content.playlists.map(\.id))
            self.libraryPodcastIds = Set(content.podcastShows.map(\.id))
            self.libraryArtistIds = Set(content.artists.map { Self.normalizedArtistId($0.id) })
            self.loadingState = .loaded
            self.logger.info(
                "Loaded \(content.playlists.count) playlists, \(content.artists.count) artists, and \(content.podcastShows.count) podcasts"
            )
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
        self.artists = []
        self.podcastShows = []
        self.libraryPlaylistIds = []
        self.libraryArtistIds = []
        self.libraryPodcastIds = []
        await self.load()
    }
}
