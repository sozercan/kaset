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

    struct PlaylistRemovalReceipt {
        fileprivate struct Target {
            let viewModel: LibraryViewModel
            let playlistRevision: UInt64
        }

        fileprivate let targets: [Target]
    }

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

    @discardableResult
    func reconcileCreatedPlaylist(
        _ playlist: Playlist,
        whileValid isCurrent: () -> Bool = { true }
    ) async -> Bool {
        for libraryViewModel in self.activeLibraryViewModels {
            guard isCurrent() else {
                self.discardCreatedPlaylist(playlist)
                return false
            }
            await libraryViewModel.refresh()
            guard isCurrent() else {
                self.discardCreatedPlaylist(playlist)
                return false
            }
            if !libraryViewModel.isInLibrary(playlistId: playlist.id) {
                libraryViewModel.addToLibrary(playlist: playlist)
            }
            libraryViewModel.markNeedsReloadOnActivation()
        }
        guard isCurrent() else {
            self.discardCreatedPlaylist(playlist)
            return false
        }
        return true
    }

    func discardCreatedPlaylist(_ playlist: Playlist) {
        for libraryViewModel in self.activeLibraryViewModels {
            libraryViewModel.discardOptimisticPlaylist(playlistId: playlist.id)
            libraryViewModel.markNeedsReloadOnActivation()
        }
    }

    @discardableResult
    func playlistRemoved(playlistId: String) -> PlaylistRemovalReceipt {
        let activeViewModels = self.activeLibraryViewModels
        var targets: [PlaylistRemovalReceipt.Target] = []
        for libraryViewModel in activeViewModels {
            let wasInLibrary = libraryViewModel.isInLibrary(playlistId: playlistId)
            libraryViewModel.markNeedsReloadOnActivation()
            libraryViewModel.removeFromLibrary(playlistId: playlistId)
            if wasInLibrary {
                targets.append(PlaylistRemovalReceipt.Target(
                    viewModel: libraryViewModel,
                    playlistRevision: libraryViewModel.playlistMutationRevision(for: playlistId)
                ))
            }
        }
        return PlaylistRemovalReceipt(targets: targets)
    }

    func rollbackPlaylistRemoval(_ playlist: Playlist, receipt: PlaylistRemovalReceipt) {
        for target in receipt.targets {
            guard target.viewModel.rollbackPlaylistRemoval(
                playlist,
                expectedPlaylistRevision: target.playlistRevision
            ) else { continue }
            target.viewModel.markNeedsReloadOnActivation()
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
    private var playlistMutationRevisionByID: [String: UInt64] = [:]

    func playlistMutationRevision(for playlistId: String) -> UInt64 {
        self.playlistMutationRevisionByID[LibraryContentIdentity.playlistKey(for: playlistId)] ?? 0
    }

    /// Whether a fresh load should run again after the current in-flight load completes.
    private var needsReloadAfterCurrentLoad = false

    /// Whether the Library view should force a refresh when it becomes active again.
    private var needsReloadOnActivation = false

    /// Bumps whenever a library mutation requests a refresh on next Library activation.
    private(set) var activationReloadGeneration: UInt64 = 0

    /// Reconciles optimistic local Library mutations against backend snapshots.
    private var contentReconciler = LibraryContentReconciler()

    /// The API client (exposed for navigation to detail views).
    let client: any YTMusicClientProtocol
    private let logger = DiagnosticsLogger.api

    init(client: any YTMusicClientProtocol, registerForLibraryMutations: Bool = true) {
        self.client = client

        if registerForLibraryMutations {
            LibraryMutationBroadcaster.shared.register(self)
        }
    }

    private var librarySnapshot: LibraryContentSnapshot {
        get {
            LibraryContentSnapshot(
                playlists: self.playlists,
                artists: self.artists,
                podcastShows: self.podcastShows,
                uploadedSongsPlaylist: self.uploadedSongsPlaylist,
                playlistIds: self.libraryPlaylistIds,
                artistIds: self.libraryArtistIds,
                podcastIds: self.libraryPodcastIds
            )
        }
        set {
            self.playlists = newValue.playlists
            self.artists = newValue.artists
            self.podcastShows = newValue.podcastShows
            self.uploadedSongsPlaylist = newValue.uploadedSongsPlaylist
            self.libraryPlaylistIds = newValue.playlistIds
            self.libraryArtistIds = newValue.artistIds
            self.libraryPodcastIds = newValue.podcastIds
        }
    }

    private var hasLibrarySnapshot: Bool {
        self.librarySnapshot.hasVisibleContent
    }

    private func markLibraryStateChanged() {
        self.libraryStateRevision &+= 1
    }

    private func markPlaylistStateChanged(_ playlistId: String) {
        self.markLibraryStateChanged()
        let playlistKey = LibraryContentIdentity.playlistKey(for: playlistId)
        self.playlistMutationRevisionByID[playlistKey, default: 0] &+= 1
    }

    @discardableResult
    func rollbackPlaylistRemoval(
        _ playlist: Playlist,
        expectedPlaylistRevision: UInt64
    ) -> Bool {
        guard self.playlistMutationRevision(for: playlist.id) == expectedPlaylistRevision,
              !self.isInLibrary(playlistId: playlist.id)
        else { return false }
        self.addToLibrary(playlist: playlist)
        return true
    }

    private func applyLibraryContent(_ content: PlaylistParser.LibraryContent) {
        let result = self.contentReconciler.apply(content, currentSnapshot: self.librarySnapshot)
        if result.preservedExistingArtists {
            self.logger.debug("Preserving existing artist snapshot because refresh fell back to landing preview")
        }
        self.librarySnapshot = result.snapshot
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
        self.contentReconciler.needsArtistReconciliation(artistIds: artistIds, expectedInLibrary: expectedInLibrary)
    }

    /// Adds a playlist ID to the library set (called after successful add to library).
    func addToLibrarySet(playlistId: String) {
        self.markPlaylistStateChanged(playlistId)
        var snapshot = self.librarySnapshot
        self.contentReconciler.addPlaylistId(playlistId, to: &snapshot)
        self.librarySnapshot = snapshot
    }

    /// Adds a playlist to the library (called after successful add to library).
    /// Updates both the ID set and the playlists array for immediate UI update.
    func addToLibrary(playlist: Playlist) {
        self.markPlaylistStateChanged(playlist.id)
        var snapshot = self.librarySnapshot
        self.contentReconciler.addPlaylist(playlist, to: &snapshot)
        self.librarySnapshot = snapshot
    }

    func discardOptimisticPlaylist(playlistId: String) {
        self.markPlaylistStateChanged(playlistId)
        var snapshot = self.librarySnapshot
        self.contentReconciler.discardAddedPlaylist(playlistId, from: &snapshot)
        self.librarySnapshot = snapshot
    }

    /// Adds a podcast to the library (called after successful subscription).
    /// Updates both the ID set and the shows array for immediate UI update.
    func addToLibrary(podcast: PodcastShow) {
        self.markLibraryStateChanged()
        var snapshot = self.librarySnapshot
        self.contentReconciler.addPodcast(podcast, to: &snapshot)
        self.librarySnapshot = snapshot
    }

    /// Adds a podcast ID to the library set (called after successful subscription).
    func addToLibrarySet(podcastId: String) {
        self.markLibraryStateChanged()
        var snapshot = self.librarySnapshot
        self.contentReconciler.addPodcastId(podcastId, to: &snapshot)
        self.librarySnapshot = snapshot
    }

    /// Adds an artist to the library (called after successful subscription).
    /// Updates both the ID set and the artists array for immediate UI update.
    func addToLibrary(artist: Artist, libraryArtistId: String? = nil) {
        self.markLibraryStateChanged()
        var snapshot = self.librarySnapshot
        self.contentReconciler.addArtist(artist, libraryArtistId: libraryArtistId, to: &snapshot)
        self.librarySnapshot = snapshot
    }

    /// Adds an artist ID to the library set (called after successful subscription).
    func addToLibrarySet(artistId: String) {
        self.markLibraryStateChanged()
        var snapshot = self.librarySnapshot
        self.contentReconciler.addArtistId(artistId, to: &snapshot)
        self.librarySnapshot = snapshot
    }

    /// Removes a playlist ID from the library set (called after successful remove from library).
    func removeFromLibrarySet(playlistId: String) {
        self.markPlaylistStateChanged(playlistId)
        var snapshot = self.librarySnapshot
        self.contentReconciler.removePlaylistId(playlistId, from: &snapshot)
        self.librarySnapshot = snapshot
    }

    /// Removes a playlist from the library (called after successful remove from library).
    /// Updates both the ID set and the playlists array for immediate UI update.
    func removeFromLibrary(playlistId: String) {
        self.markPlaylistStateChanged(playlistId)
        var snapshot = self.librarySnapshot
        self.contentReconciler.removePlaylist(playlistId, from: &snapshot)
        self.librarySnapshot = snapshot
    }

    /// Removes a podcast from the library (called after successful unsubscribe).
    /// Updates both the ID set and the shows array for immediate UI update.
    func removeFromLibrary(podcastId: String) {
        self.markLibraryStateChanged()
        var snapshot = self.librarySnapshot
        self.contentReconciler.removePodcast(podcastId, from: &snapshot)
        self.librarySnapshot = snapshot
    }

    /// Removes a podcast ID from the library set (called after successful unsubscribe).
    func removeFromLibrarySet(podcastId: String) {
        self.markLibraryStateChanged()
        var snapshot = self.librarySnapshot
        self.contentReconciler.removePodcastId(podcastId, from: &snapshot)
        self.librarySnapshot = snapshot
    }

    /// Removes an artist from the library (called after successful unsubscribe).
    /// Updates both the ID set and the artists array for immediate UI update.
    func removeFromLibrary(artistId: String) {
        self.markLibraryStateChanged()
        var snapshot = self.librarySnapshot
        self.contentReconciler.removeArtist(artistId, from: &snapshot)
        self.librarySnapshot = snapshot
    }

    /// Removes an artist ID from the library set (called after successful unsubscribe).
    func removeFromLibrarySet(artistId: String) {
        self.markLibraryStateChanged()
        var snapshot = self.librarySnapshot
        self.contentReconciler.removeArtistId(artistId, from: &snapshot)
        self.librarySnapshot = snapshot
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
            self.librarySnapshot = .empty
        }

        await self.load()
    }
}
