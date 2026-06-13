import Foundation
import Observation
import os

// MARK: - LibraryMutationBroadcaster

/// Broadcasts library mutations to every active LibraryViewModel.
///
/// Context menus can be presented from views that do not reliably have the same
/// LibraryViewModel instance as the Library tab. This keeps library mutations
/// optimistic and app-wide instead of relying only on the local environment.
@MainActor
final class LibraryMutationBroadcaster {
    static let shared = LibraryMutationBroadcaster()

    private final class WeakLibraryViewModelBox {
        weak var value: LibraryViewModel?

        init(_ value: LibraryViewModel) {
            self.value = value
        }
    }

    private var libraryViewModels: [ObjectIdentifier: WeakLibraryViewModelBox] = [:]

    private init() {}

    func register(_ libraryViewModel: LibraryViewModel) {
        self.pruneReleasedViewModels()
        self.libraryViewModels[ObjectIdentifier(libraryViewModel)] = WeakLibraryViewModelBox(libraryViewModel)
    }

    private var activeLibraryViewModels: [LibraryViewModel] {
        self.pruneReleasedViewModels()
        return self.libraryViewModels.values.compactMap(\.value)
    }

    private func pruneReleasedViewModels() {
        self.libraryViewModels = self.libraryViewModels.filter { $0.value.value != nil }
    }

    func playlistCreated(_ playlist: Playlist) {
        for libraryViewModel in self.activeLibraryViewModels {
            libraryViewModel.markNeedsReloadOnActivation()
            libraryViewModel.addToLibrary(playlist: playlist)
        }
    }

    func reconcileCreatedPlaylist(_ playlist: Playlist) async {
        for libraryViewModel in self.activeLibraryViewModels {
            await libraryViewModel.refresh()
            if !libraryViewModel.isInLibrary(playlistId: playlist.id) {
                libraryViewModel.addToLibrary(playlist: playlist)
            }
            libraryViewModel.markNeedsReloadOnActivation()
        }
    }

    func playlistRemoved(playlistId: String) {
        for libraryViewModel in self.activeLibraryViewModels {
            libraryViewModel.markNeedsReloadOnActivation()
            libraryViewModel.removeFromLibrary(playlistId: playlistId)
        }
    }

    func reconcileRemovedPlaylist(playlistId: String) async {
        for libraryViewModel in self.activeLibraryViewModels {
            await libraryViewModel.refresh()
            if libraryViewModel.isInLibrary(playlistId: playlistId) {
                libraryViewModel.removeFromLibrary(playlistId: playlistId)
            }
            libraryViewModel.markNeedsReloadOnActivation()
        }
    }
}

// MARK: - LibraryViewModel

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

    /// Virtual playlist entry for user-uploaded songs, when available.
    private(set) var uploadedSongsPlaylist: Playlist?

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

    /// Playlist additions that should stay visible until the server starts returning them consistently.
    private var pendingAddedPlaylists: [String: Playlist] = [:]

    /// Consecutive backend matches for optimistic playlist additions.
    private var pendingAddedPlaylistMatchCounts: [String: Int] = [:]

    /// Playlist removals that should stay suppressed until the server stops returning them consistently.
    private var pendingRemovedPlaylistIds: Set<String> = []

    /// Consecutive backend misses for optimistic playlist removals.
    private var pendingRemovedPlaylistMissCounts: [String: Int] = [:]

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

    private static let playlistMutationStableMatchCount = 2
    private static let artistMutationStableMatchCount = 2

    init(client: any YTMusicClientProtocol, registerForLibraryMutations: Bool = true) {
        self.client = client

        if registerForLibraryMutations {
            LibraryMutationBroadcaster.shared.register(self)
        }
    }

    private var hasLibrarySnapshot: Bool {
        !self.playlists.isEmpty || !self.artists.isEmpty || !self.podcastShows.isEmpty
            || self.uploadedSongsPlaylist != nil
            || !self.libraryPlaylistIds.isEmpty || !self.libraryArtistIds.isEmpty || !self.libraryPodcastIds.isEmpty
    }

    private func markLibraryStateChanged() {
        self.libraryStateRevision &+= 1
    }

    private func applyLibraryContent(_ content: PlaylistParser.LibraryContent) { // swiftlint:disable:this cyclomatic_complexity
        self.uploadedSongsPlaylist = content.uploadedSongsPlaylist
        self.podcastShows = content.podcastShows
        self.libraryPodcastIds = Set(content.podcastShows.map(\.id))

        let rawPlaylistKeys = Set(content.playlists.map { LibraryContentIdentity.playlistKey(for: $0.id) })
        for playlistKey in Array(self.pendingAddedPlaylists.keys) {
            if rawPlaylistKeys.contains(playlistKey) {
                self.pendingAddedPlaylistMatchCounts[playlistKey, default: 0] += 1
                if self.pendingAddedPlaylistMatchCounts[playlistKey, default: 0] >= Self.playlistMutationStableMatchCount {
                    self.pendingAddedPlaylists.removeValue(forKey: playlistKey)
                    self.pendingAddedPlaylistMatchCounts.removeValue(forKey: playlistKey)
                }
            } else {
                self.pendingAddedPlaylistMatchCounts[playlistKey] = 0
            }
        }

        for playlistKey in Array(self.pendingRemovedPlaylistIds) {
            if rawPlaylistKeys.contains(playlistKey) {
                self.pendingRemovedPlaylistMissCounts[playlistKey] = 0
                continue
            }

            self.pendingRemovedPlaylistMissCounts[playlistKey, default: 0] += 1
            if self.pendingRemovedPlaylistMissCounts[playlistKey, default: 0] >= Self.playlistMutationStableMatchCount {
                self.pendingRemovedPlaylistIds.remove(playlistKey)
                self.pendingRemovedPlaylistMissCounts.removeValue(forKey: playlistKey)
            }
        }

        var playlists = content.playlists.filter { playlist in
            !self.pendingRemovedPlaylistIds.contains(LibraryContentIdentity.playlistKey(for: playlist.id))
        }
        playlists = LibraryContentIdentity.deduplicatedPlaylists(playlists)
        var visiblePlaylistKeys = Set(playlists.map { LibraryContentIdentity.playlistKey(for: $0.id) })

        for (playlistKey, playlist) in self.pendingAddedPlaylists where !visiblePlaylistKeys.contains(playlistKey) {
            playlists.insert(playlist, at: 0)
            visiblePlaylistKeys.insert(playlistKey)
        }

        self.playlists = playlists
        self.libraryPlaylistIds = Set(playlists.map(\.id))

        let sourceArtists: [Artist]
        if content.artistsSource == .landingFallback, !self.artists.isEmpty {
            self.logger.debug("Preserving existing artist snapshot because refresh fell back to landing preview")
            sourceArtists = self.artists
        } else {
            sourceArtists = content.artists
        }

        let canonicalArtists = sourceArtists.map { LibraryContentIdentity.canonicalArtist($0) }
        let rawArtistKeys = Set(canonicalArtists.map(\.id))

        if content.artistsSource == .dedicated {
            for artistKey in Array(self.pendingAddedArtists.keys) {
                if rawArtistKeys.contains(artistKey) {
                    self.pendingAddedArtistMatchCounts[artistKey, default: 0] += 1
                    if self.pendingAddedArtistMatchCounts[artistKey, default: 0] >= Self.artistMutationStableMatchCount {
                        self.pendingAddedArtists.removeValue(forKey: artistKey)
                        self.pendingAddedArtistMatchCounts.removeValue(forKey: artistKey)
                    }
                } else {
                    self.pendingAddedArtistMatchCounts[artistKey] = 0
                }
            }

            for artistKey in Array(self.pendingRemovedArtistIds) {
                if rawArtistKeys.contains(artistKey) {
                    self.pendingRemovedArtistMatchCounts[artistKey] = 0
                    continue
                }

                self.pendingRemovedArtistMatchCounts[artistKey, default: 0] += 1
                if self.pendingRemovedArtistMatchCounts[artistKey, default: 0] >= Self.artistMutationStableMatchCount {
                    self.pendingRemovedArtistIds.remove(artistKey)
                    self.pendingRemovedArtistMatchCounts.removeValue(forKey: artistKey)
                }
            }
        }

        var artists = canonicalArtists.filter { artist in
            !self.pendingRemovedArtistIds.contains(artist.id)
        }
        artists = LibraryContentIdentity.deduplicatedArtists(artists)
        var visibleArtistKeys = Set(artists.map(\.id))

        for (artistKey, artist) in self.pendingAddedArtists where !visibleArtistKeys.contains(artistKey) {
            artists.insert(artist, at: 0)
            visibleArtistKeys.insert(artistKey)
        }

        self.artists = artists
        self.libraryArtistIds = visibleArtistKeys
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
        LibraryContentIdentity.containsPlaylist(playlistId, in: self.libraryPlaylistIds)
    }

    /// Checks if a podcast show is in the user's library.
    func isInLibrary(podcastId: String) -> Bool {
        self.libraryPodcastIds.contains(podcastId)
    }

    /// Checks if an artist is in the user's library.
    func isInLibrary(artistId: String) -> Bool {
        self.libraryArtistIds.contains(LibraryContentIdentity.artistKey(for: artistId))
    }

    /// Whether artist library state still depends on optimistic local suppression/insertion.
    func needsArtistLibraryReconciliation(artistIds: [String], expectedInLibrary: Bool) -> Bool {
        let artistKeys = Set(artistIds.map { LibraryContentIdentity.artistKey(for: $0) })
        if expectedInLibrary {
            return artistKeys.contains { self.pendingAddedArtists[$0] != nil }
        }
        return artistKeys.contains { self.pendingRemovedArtistIds.contains($0) }
    }

    /// Adds a playlist ID to the library set (called after successful add to library).
    func addToLibrarySet(playlistId: String) {
        self.markLibraryStateChanged()
        let playlistKey = LibraryContentIdentity.playlistKey(for: playlistId)
        self.pendingRemovedPlaylistIds.remove(playlistKey)
        self.pendingRemovedPlaylistMissCounts.removeValue(forKey: playlistKey)
        self.libraryPlaylistIds.insert(playlistId)
    }

    /// Adds a playlist to the library (called after successful add to library).
    /// Updates both the ID set and the playlists array for immediate UI update.
    func addToLibrary(playlist: Playlist) {
        self.markLibraryStateChanged()
        self.libraryPlaylistIds.insert(playlist.id)
        let playlistKey = LibraryContentIdentity.playlistKey(for: playlist.id)
        self.pendingRemovedPlaylistIds.remove(playlistKey)
        self.pendingRemovedPlaylistMissCounts.removeValue(forKey: playlistKey)
        self.pendingAddedPlaylists[playlistKey] = playlist
        self.pendingAddedPlaylistMatchCounts[playlistKey] = 0
        if let existingIndex = self.playlists.firstIndex(where: { LibraryContentIdentity.playlistKey(for: $0.id) == playlistKey }) {
            self.playlists[existingIndex] = playlist
        } else {
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
        let artistKey = LibraryContentIdentity.artistKey(for: libraryArtistId ?? artist.id)
        let canonicalArtist = LibraryContentIdentity.canonicalArtist(artist, libraryArtistID: artistKey)
        self.pendingRemovedArtistIds.remove(artistKey)
        self.pendingRemovedArtistMatchCounts.removeValue(forKey: artistKey)
        self.pendingAddedArtists[artistKey] = canonicalArtist
        self.pendingAddedArtistMatchCounts[artistKey] = 0
        self.libraryArtistIds.insert(artistKey)
        if let existingIndex = self.artists.firstIndex(where: { LibraryContentIdentity.artistKey(for: $0.id) == artistKey }) {
            self.artists[existingIndex] = canonicalArtist
        } else {
            self.artists.insert(canonicalArtist, at: 0)
        }
    }

    /// Adds an artist ID to the library set (called after successful subscription).
    func addToLibrarySet(artistId: String) {
        self.markLibraryStateChanged()
        let artistKey = LibraryContentIdentity.artistKey(for: artistId)
        self.pendingRemovedArtistIds.remove(artistKey)
        self.pendingRemovedArtistMatchCounts.removeValue(forKey: artistKey)
        self.libraryArtistIds.insert(artistKey)
    }

    /// Removes a playlist ID from the library set (called after successful remove from library).
    func removeFromLibrarySet(playlistId: String) {
        self.markLibraryStateChanged()
        let playlistKey = LibraryContentIdentity.playlistKey(for: playlistId)
        self.pendingAddedPlaylists.removeValue(forKey: playlistKey)
        self.pendingAddedPlaylistMatchCounts.removeValue(forKey: playlistKey)
        self.pendingRemovedPlaylistIds.insert(playlistKey)
        self.pendingRemovedPlaylistMissCounts[playlistKey] = 0
        self.libraryPlaylistIds = LibraryContentIdentity.removingPlaylist(playlistId, from: self.libraryPlaylistIds)
    }

    /// Removes a playlist from the library (called after successful remove from library).
    /// Updates both the ID set and the playlists array for immediate UI update.
    func removeFromLibrary(playlistId: String) {
        self.markLibraryStateChanged()
        self.removeFromLibrarySet(playlistId: playlistId)
        let playlistKey = LibraryContentIdentity.playlistKey(for: playlistId)
        self.playlists.removeAll { LibraryContentIdentity.playlistKey(for: $0.id) == playlistKey }
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
        let artistKey = LibraryContentIdentity.artistKey(for: artistId)
        self.pendingAddedArtists.removeValue(forKey: artistKey)
        self.pendingAddedArtistMatchCounts.removeValue(forKey: artistKey)
        self.pendingRemovedArtistIds.insert(artistKey)
        self.pendingRemovedArtistMatchCounts[artistKey] = 0
        self.libraryArtistIds.remove(artistKey)
        self.artists.removeAll { LibraryContentIdentity.artistKey(for: $0.id) == artistKey }
    }

    /// Removes an artist ID from the library set (called after successful unsubscribe).
    func removeFromLibrarySet(artistId: String) {
        self.markLibraryStateChanged()
        let artistKey = LibraryContentIdentity.artistKey(for: artistId)
        self.pendingAddedArtists.removeValue(forKey: artistKey)
        self.pendingAddedArtistMatchCounts.removeValue(forKey: artistKey)
        self.pendingRemovedArtistIds.insert(artistKey)
        self.pendingRemovedArtistMatchCounts[artistKey] = 0
        self.libraryArtistIds.remove(artistKey)
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
            self.uploadedSongsPlaylist = nil
            self.libraryPlaylistIds = []
            self.libraryArtistIds = []
            self.libraryPodcastIds = []
        }

        await self.load()
    }
}
