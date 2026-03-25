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

    /// Monotonic revision for local library state mutations.
    private var libraryStateRevision: UInt64 = 0

    /// Whether a fresh load should run again after the current in-flight load completes.
    private var needsReloadAfterCurrentLoad = false

    /// Whether the Library view should force a refresh when it becomes active again.
    private var needsReloadOnActivation = false

    /// Bumps whenever a library mutation requests a refresh on next Library activation.
    private(set) var activationReloadGeneration: UInt64 = 0

    /// Artist additions that should stay visible until the server starts returning them.
    private var pendingAddedArtists: [String: Artist] = [:]

    /// Consecutive backend matches for optimistic artist additions.
    private var pendingAddedArtistMatchCounts: [String: Int] = [:]

    /// Artist removals that should stay suppressed until the server stops returning them.
    private var pendingRemovedArtistIds: Set<String> = []

    /// Consecutive backend matches for optimistic artist removals.
    private var pendingRemovedArtistMatchCounts: [String: Int] = [:]

    /// The API client (exposed for navigation to detail views).
    let client: any YTMusicClientProtocol
    private let logger = DiagnosticsLogger.api

    private static let artistMutationStableMatchCount = 2

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
        Artist.publicChannelId(for: artistId) ?? artistId
    }

    private static func canonicalArtist(_ artist: Artist, normalizedArtistId: String) -> Artist {
        if artist.id == normalizedArtistId {
            return artist
        }

        return Artist(
            id: normalizedArtistId,
            name: artist.name,
            thumbnailURL: artist.thumbnailURL
        )
    }

    private static func deduplicatedArtists(_ artists: [Artist]) -> [Artist] {
        var seenArtistIds: Set<String> = []
        var deduplicatedArtists: [Artist] = []

        for artist in artists {
            guard seenArtistIds.insert(artist.id).inserted else { continue }
            deduplicatedArtists.append(artist)
        }

        return deduplicatedArtists
    }

    private var hasLibrarySnapshot: Bool {
        !self.playlists.isEmpty || !self.artists.isEmpty || !self.podcastShows.isEmpty
            || !self.libraryPlaylistIds.isEmpty || !self.libraryArtistIds.isEmpty || !self.libraryPodcastIds.isEmpty
    }

    private func markLibraryStateChanged() {
        self.libraryStateRevision &+= 1
    }

    private func applyLibraryContent(_ content: PlaylistParser.LibraryContent) {
        self.playlists = content.playlists
        self.podcastShows = content.podcastShows
        self.libraryPlaylistIds = Set(content.playlists.map(\.id))
        self.libraryPodcastIds = Set(content.podcastShows.map(\.id))

        let sourceArtists: [Artist]
        if content.artistsSource == .landingFallback, !self.artists.isEmpty {
            self.logger.debug("Preserving existing artist snapshot because refresh fell back to landing preview")
            sourceArtists = self.artists
        } else {
            sourceArtists = content.artists
        }

        let canonicalArtists = sourceArtists.map { artist in
            let normalizedArtistId = Self.normalizedArtistId(artist.id)
            return Self.canonicalArtist(artist, normalizedArtistId: normalizedArtistId)
        }
        let rawArtistIds = Set(canonicalArtists.map(\.id))

        if content.artistsSource == .dedicated {
            for normalizedArtistId in self.pendingAddedArtists.keys {
                if rawArtistIds.contains(normalizedArtistId) {
                    self.pendingAddedArtistMatchCounts[normalizedArtistId, default: 0] += 1
                    if self.pendingAddedArtistMatchCounts[normalizedArtistId, default: 0] >= Self.artistMutationStableMatchCount {
                        self.pendingAddedArtists.removeValue(forKey: normalizedArtistId)
                        self.pendingAddedArtistMatchCounts.removeValue(forKey: normalizedArtistId)
                    }
                } else {
                    self.pendingAddedArtistMatchCounts[normalizedArtistId] = 0
                }
            }

            for normalizedArtistId in Array(self.pendingRemovedArtistIds) {
                if rawArtistIds.contains(normalizedArtistId) {
                    self.pendingRemovedArtistMatchCounts[normalizedArtistId] = 0
                    continue
                }

                self.pendingRemovedArtistMatchCounts[normalizedArtistId, default: 0] += 1
                if self.pendingRemovedArtistMatchCounts[normalizedArtistId, default: 0] >= Self.artistMutationStableMatchCount {
                    self.pendingRemovedArtistIds.remove(normalizedArtistId)
                    self.pendingRemovedArtistMatchCounts.removeValue(forKey: normalizedArtistId)
                }
            }
        }

        var artists = canonicalArtists.filter { artist in
            !self.pendingRemovedArtistIds.contains(artist.id)
        }
        artists = Self.deduplicatedArtists(artists)
        var visibleArtistIds = Set(artists.map(\.id))

        for (normalizedArtistId, artist) in self.pendingAddedArtists where !visibleArtistIds.contains(normalizedArtistId) {
            artists.insert(artist, at: 0)
            visibleArtistIds.insert(normalizedArtistId)
        }

        self.artists = artists
        self.libraryArtistIds = visibleArtistIds
    }

    private func finishDiscardedLoad() async {
        if self.needsReloadAfterCurrentLoad {
            self.needsReloadAfterCurrentLoad = false
            self.loadingState = self.hasLibrarySnapshot ? .loadingMore : .idle
            await self.load()
            return
        }

        self.loadingState = self.hasLibrarySnapshot ? .loaded : .idle
    }

    func markNeedsReloadOnActivation() {
        self.needsReloadOnActivation = true
        self.activationReloadGeneration &+= 1
    }

    func reloadIfNeededOnActivation() async {
        guard self.needsReloadOnActivation else { return }
        self.needsReloadOnActivation = false
        await self.refresh()
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

    /// Whether artist library state still depends on optimistic local suppression/insertion.
    func needsArtistLibraryReconciliation(artistIds: [String], expectedInLibrary: Bool) -> Bool {
        let normalizedArtistIds = Set(artistIds.map(Self.normalizedArtistId))
        if expectedInLibrary {
            return normalizedArtistIds.contains { self.pendingAddedArtists[$0] != nil }
        }
        return normalizedArtistIds.contains { self.pendingRemovedArtistIds.contains($0) }
    }

    /// Adds a playlist ID to the library set (called after successful add to library).
    func addToLibrarySet(playlistId: String) {
        self.markLibraryStateChanged()
        self.libraryPlaylistIds.insert(playlistId)
    }

    /// Adds a playlist to the library (called after successful add to library).
    /// Updates both the ID set and the playlists array for immediate UI update.
    func addToLibrary(playlist: Playlist) {
        self.markLibraryStateChanged()
        self.libraryPlaylistIds.insert(playlist.id)
        let normalizedPlaylistId = Self.normalizedPlaylistId(playlist.id)
        if !self.playlists.contains(where: { Self.normalizedPlaylistId($0.id) == normalizedPlaylistId }) {
            self.playlists.insert(playlist, at: 0)
        }
    }

    /// Adds a podcast to the library (called after successful subscription).
    /// Updates both the ID set and the shows array for immediate UI update.
    func addToLibrary(podcast: PodcastShow) {
        self.markLibraryStateChanged()
        self.libraryPodcastIds.insert(podcast.id)
        // Add to shows array if not already present
        if !self.podcastShows.contains(where: { $0.id == podcast.id }) {
            self.podcastShows.insert(podcast, at: 0)
        }
    }

    /// Adds a podcast ID to the library set (called after successful subscription).
    func addToLibrarySet(podcastId: String) {
        self.markLibraryStateChanged()
        self.libraryPodcastIds.insert(podcastId)
    }

    /// Adds an artist to the library (called after successful subscription).
    /// Updates both the ID set and the artists array for immediate UI update.
    func addToLibrary(artist: Artist, libraryArtistId: String? = nil) {
        self.markLibraryStateChanged()
        let normalizedArtistId = Self.normalizedArtistId(libraryArtistId ?? artist.id)
        let canonicalArtist = Self.canonicalArtist(artist, normalizedArtistId: normalizedArtistId)
        self.pendingRemovedArtistIds.remove(normalizedArtistId)
        self.pendingRemovedArtistMatchCounts.removeValue(forKey: normalizedArtistId)
        self.pendingAddedArtists[normalizedArtistId] = canonicalArtist
        self.pendingAddedArtistMatchCounts[normalizedArtistId] = 0
        self.libraryArtistIds.insert(normalizedArtistId)
        if let existingIndex = self.artists.firstIndex(where: { Self.normalizedArtistId($0.id) == normalizedArtistId }) {
            self.artists[existingIndex] = canonicalArtist
        } else {
            self.artists.insert(canonicalArtist, at: 0)
        }
    }

    /// Adds an artist ID to the library set (called after successful subscription).
    func addToLibrarySet(artistId: String) {
        self.markLibraryStateChanged()
        let normalizedArtistId = Self.normalizedArtistId(artistId)
        self.pendingRemovedArtistIds.remove(normalizedArtistId)
        self.pendingRemovedArtistMatchCounts.removeValue(forKey: normalizedArtistId)
        self.libraryArtistIds.insert(normalizedArtistId)
    }

    /// Removes a playlist ID from the library set (called after successful remove from library).
    func removeFromLibrarySet(playlistId: String) {
        self.markLibraryStateChanged()
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
        self.markLibraryStateChanged()
        self.removeFromLibrarySet(playlistId: playlistId)
        let normalizedPlaylistId = Self.normalizedPlaylistId(playlistId)
        self.playlists.removeAll { Self.normalizedPlaylistId($0.id) == normalizedPlaylistId }
    }

    /// Removes a podcast from the library (called after successful unsubscribe).
    /// Updates both the ID set and the shows array for immediate UI update.
    func removeFromLibrary(podcastId: String) {
        self.markLibraryStateChanged()
        self.libraryPodcastIds.remove(podcastId)
        self.podcastShows.removeAll { $0.id == podcastId }
    }

    /// Removes a podcast ID from the library set (called after successful unsubscribe).
    func removeFromLibrarySet(podcastId: String) {
        self.markLibraryStateChanged()
        self.libraryPodcastIds.remove(podcastId)
    }

    /// Removes an artist from the library (called after successful unsubscribe).
    /// Updates both the ID set and the artists array for immediate UI update.
    func removeFromLibrary(artistId: String) {
        self.markLibraryStateChanged()
        let normalizedArtistId = Self.normalizedArtistId(artistId)
        self.pendingAddedArtists.removeValue(forKey: normalizedArtistId)
        self.pendingAddedArtistMatchCounts.removeValue(forKey: normalizedArtistId)
        self.pendingRemovedArtistIds.insert(normalizedArtistId)
        self.pendingRemovedArtistMatchCounts[normalizedArtistId] = 0
        self.libraryArtistIds.remove(normalizedArtistId)
        self.artists.removeAll { Self.normalizedArtistId($0.id) == normalizedArtistId }
    }

    /// Removes an artist ID from the library set (called after successful unsubscribe).
    func removeFromLibrarySet(artistId: String) {
        self.markLibraryStateChanged()
        let normalizedArtistId = Self.normalizedArtistId(artistId)
        self.pendingAddedArtists.removeValue(forKey: normalizedArtistId)
        self.pendingAddedArtistMatchCounts.removeValue(forKey: normalizedArtistId)
        self.pendingRemovedArtistIds.insert(normalizedArtistId)
        self.pendingRemovedArtistMatchCounts[normalizedArtistId] = 0
        self.libraryArtistIds.remove(normalizedArtistId)
    }

    /// Loads library content (playlists, artists, and podcasts).
    func load() async {
        guard self.loadingState != .loading else { return }

        if self.loadingState != .loadingMore {
            self.loadingState = .loading
        }
        let requestRevision = self.libraryStateRevision
        self.logger.info("Loading library content")

        do {
            let content = try await client.getLibraryContent()

            if requestRevision != self.libraryStateRevision {
                self.logger.debug("Discarding stale library load because local library state changed during the request")
                await self.finishDiscardedLoad()
                return
            }

            self.applyLibraryContent(content)
            self.loadingState = .loaded
            self.logger.info(
                "Loaded \(content.playlists.count) playlists, \(content.artists.count) artists, and \(content.podcastShows.count) podcasts"
            )

            if self.needsReloadAfterCurrentLoad {
                self.needsReloadAfterCurrentLoad = false
                self.loadingState = self.hasLibrarySnapshot ? .loadingMore : .idle
                await self.load()
            }
        } catch is CancellationError {
            // Task was cancelled (e.g., user navigated away) — reset to idle so it can retry
            self.logger.debug("Library load cancelled")
            self.loadingState = self.hasLibrarySnapshot ? .loaded : .idle
        } catch {
            self.logger.error("Failed to load library: \(error.localizedDescription)")
            if self.hasLibrarySnapshot {
                self.loadingState = .loaded
            } else {
                self.loadingState = .error(LoadingError(from: error))
            }
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
        self.markLibraryStateChanged()

        if self.loadingState == .loading || self.loadingState == .loadingMore {
            self.needsReloadAfterCurrentLoad = true
            self.logger.debug("Library refresh queued until in-flight load finishes")
            return
        }

        if self.hasLibrarySnapshot {
            self.loadingState = .loadingMore
        } else {
            self.playlists = []
            self.artists = []
            self.podcastShows = []
            self.libraryPlaylistIds = []
            self.libraryArtistIds = []
            self.libraryPodcastIds = []
        }

        await self.load()
    }
}
