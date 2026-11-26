import Foundation
import Observation
import os

@MainActor
final class LibraryMutationBroadcaster {
    static let shared = LibraryMutationBroadcaster()

    struct PlaylistRemovalReceipt {
        fileprivate struct Target {
            let viewModel: LibraryViewModel
            let playlistRevision: UInt64
            let accountScopeGeneration: UInt64
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

    func playlistAdded(_ playlist: Playlist) {
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

    @discardableResult
    func reconcileAddedPlaylist(
        _ playlist: Playlist,
        whileValid isCurrent: () -> Bool = { true }
    ) async -> Bool {
        for libraryViewModel in self.activeLibraryViewModels {
            guard isCurrent() else { return false }
            await libraryViewModel.refresh()
            guard isCurrent() else { return false }
            if !libraryViewModel.isInLibrary(playlistId: playlist.id) {
                libraryViewModel.addToLibrary(playlist: playlist)
            }
            libraryViewModel.markNeedsReloadOnActivation()
        }
        return isCurrent()
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
                    playlistRevision: libraryViewModel.playlistMutationRevision(for: playlistId),
                    accountScopeGeneration: libraryViewModel.currentAccountScopeGeneration
                ))
            }
        }
        return PlaylistRemovalReceipt(targets: targets)
    }

    func rollbackPlaylistRemoval(_ playlist: Playlist, receipt: PlaylistRemovalReceipt) {
        for target in receipt.targets {
            guard target.viewModel.currentAccountScopeGeneration == target.accountScopeGeneration else { continue }
            guard target.viewModel.rollbackPlaylistRemoval(
                playlist,
                expectedPlaylistRevision: target.playlistRevision
            ) else { continue }
            target.viewModel.markNeedsReloadOnActivation()
        }
    }

    @discardableResult
    func reconcileRemovedPlaylist(
        playlistId: String,
        whileValid isCurrent: () -> Bool = { true }
    ) async -> Bool {
        for libraryViewModel in self.activeLibraryViewModels {
            guard isCurrent() else { return false }
            await libraryViewModel.refresh()
            guard isCurrent() else { return false }
            if libraryViewModel.isInLibrary(playlistId: playlistId) {
                libraryViewModel.removeFromLibrary(playlistId: playlistId)
            }
            libraryViewModel.markNeedsReloadOnActivation()
        }
        return isCurrent()
    }

    func albumAdded(_ album: Album) {
        for libraryViewModel in self.activeLibraryViewModels {
            libraryViewModel.markNeedsReloadOnActivation()
            libraryViewModel.addToLibrary(album: album)
        }
    }

    @discardableResult
    func reconcileAddedAlbum(
        _ album: Album,
        whileValid isCurrent: () -> Bool = { true }
    ) async -> Bool {
        for libraryViewModel in self.activeLibraryViewModels {
            guard isCurrent() else { return false }
            await libraryViewModel.refresh()
            guard isCurrent() else { return false }
            if !libraryViewModel.isInLibrary(
                albumId: album.id,
                targetPlaylistId: album.libraryTargetId
            ) {
                guard isCurrent() else { return false }
                libraryViewModel.addToLibrary(album: album)
            }
            libraryViewModel.markNeedsReloadOnActivation()
        }
        return isCurrent()
    }

    func albumRemoved(albumId: String, targetPlaylistId: String?) {
        for libraryViewModel in self.activeLibraryViewModels {
            libraryViewModel.markNeedsReloadOnActivation()
            libraryViewModel.removeFromLibrary(albumId: albumId, targetPlaylistId: targetPlaylistId)
        }
    }

    @discardableResult
    func reconcileRemovedAlbum(
        albumId: String,
        targetPlaylistId: String?,
        whileValid isCurrent: () -> Bool = { true }
    ) async -> Bool {
        for libraryViewModel in self.activeLibraryViewModels {
            guard isCurrent() else { return false }
            await libraryViewModel.refresh()
            guard isCurrent() else { return false }
            if libraryViewModel.isInLibrary(albumId: albumId, targetPlaylistId: targetPlaylistId) {
                guard isCurrent() else { return false }
                libraryViewModel.removeFromLibrary(albumId: albumId, targetPlaylistId: targetPlaylistId)
            }
            libraryViewModel.markNeedsReloadOnActivation()
        }
        return isCurrent()
    }
}

@MainActor
@Observable
final class LibraryViewModel {
    private(set) var loadingState: LoadingState = .idle

    private(set) var playlists: [Playlist] = []

    private(set) var albums: [Album] = []

    private(set) var artists: [Artist] = []

    private(set) var podcastShows: [PodcastShow] = []

    private(set) var uploadedSongsPlaylist: Playlist?

    private(set) var libraryPlaylistIds: Set<String> = []

    private(set) var libraryPodcastIds: Set<String> = []

    private(set) var libraryArtistIds: Set<String> = []

    private var libraryAccountScope: String?
    private var accountScopeGeneration: UInt64 = 0

    var currentAccountScope: String? {
        self.libraryAccountScope
    }

    var currentAccountScopeGeneration: UInt64 {
        self.accountScopeGeneration
    }

    private var libraryAlbumsSource: LibraryContentParser.LibraryAlbumsSource?

    private var libraryStateRevision: UInt64 = 0
    private var playlistMutationRevisionByID: [String: UInt64] = [:]

    func playlistMutationRevision(for playlistId: String) -> UInt64 {
        self.playlistMutationRevisionByID[LibraryContentIdentity.playlistKey(for: playlistId)] ?? 0
    }

    private var needsReloadAfterCurrentLoad = false

    private var needsReloadOnActivation = false

    private(set) var activationReloadGeneration: UInt64 = 0

    private var contentReconciler = LibraryContentReconciler()

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
                albums: self.albums,
                artists: self.artists,
                podcastShows: self.podcastShows,
                uploadedSongsPlaylist: self.uploadedSongsPlaylist,
                playlistIds: self.libraryPlaylistIds,
                artistIds: self.libraryArtistIds,
                podcastIds: self.libraryPodcastIds,
                accountScope: self.libraryAccountScope,
                albumsSource: self.libraryAlbumsSource
            )
        }
        set {
            self.playlists = newValue.playlists
            self.albums = newValue.albums
            self.artists = newValue.artists
            self.podcastShows = newValue.podcastShows
            self.uploadedSongsPlaylist = newValue.uploadedSongsPlaylist
            self.libraryPlaylistIds = newValue.playlistIds
            self.libraryArtistIds = newValue.artistIds
            self.libraryPodcastIds = newValue.podcastIds
            self.libraryAccountScope = newValue.accountScope
            self.libraryAlbumsSource = newValue.albumsSource
        }
    }

    private var hasLibrarySnapshot: Bool {
        self.librarySnapshot.hasLoadedContent
    }

    func activateAccountScope(_ accountScope: String?, isPrimary: Bool = false) {
        guard self.libraryAccountScope != accountScope else { return }

        self.markLibraryStateChanged()
        let shouldClearState = self.libraryAccountScope != nil
            || (accountScope != nil && !isPrimary && accountScope != "primary")
        if shouldClearState {
            self.accountScopeGeneration &+= 1
            self.librarySnapshot = .empty
            self.contentReconciler = LibraryContentReconciler()
        }
        self.libraryAccountScope = accountScope
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
        if result.preservedExistingAlbums {
            self.logger.debug("Preserving existing album snapshot because refresh fell back to landing preview")
        }
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

    func isInLibrary(playlistId: String) -> Bool {
        LibraryContentIdentity.containsPlaylist(playlistId, in: self.libraryPlaylistIds)
    }

    func isInLibrary(albumId: String, targetPlaylistId: String? = nil) -> Bool {
        self.albums.contains { album in
            if album.id == albumId {
                return true
            }
            guard let targetPlaylistId else { return false }
            return album.libraryTargetId == targetPlaylistId
        }
    }

    func isInLibrary(podcastId: String) -> Bool {
        self.libraryPodcastIds.contains(podcastId)
    }

    func isInLibrary(artistId: String) -> Bool {
        self.libraryArtistIds.contains(LibraryContentIdentity.artistKey(for: artistId))
    }

    func needsArtistLibraryReconciliation(artistIds: [String], expectedInLibrary: Bool) -> Bool {
        self.contentReconciler.needsArtistReconciliation(artistIds: artistIds, expectedInLibrary: expectedInLibrary)
    }

    func addToLibrarySet(playlistId: String) {
        self.markPlaylistStateChanged(playlistId)
        var snapshot = self.librarySnapshot
        self.contentReconciler.addPlaylistId(playlistId, to: &snapshot)
        self.librarySnapshot = snapshot
    }

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

    func addToLibrary(album: Album) {
        self.markLibraryStateChanged()
        var snapshot = self.librarySnapshot
        self.contentReconciler.addAlbum(album, to: &snapshot)
        self.librarySnapshot = snapshot
    }

    func addToLibrary(podcast: PodcastShow) {
        self.markLibraryStateChanged()
        var snapshot = self.librarySnapshot
        self.contentReconciler.addPodcast(podcast, to: &snapshot)
        self.librarySnapshot = snapshot
    }

    func addToLibrarySet(podcastId: String) {
        self.markLibraryStateChanged()
        var snapshot = self.librarySnapshot
        self.contentReconciler.addPodcastId(podcastId, to: &snapshot)
        self.librarySnapshot = snapshot
    }

    func addToLibrary(artist: Artist, libraryArtistId: String? = nil) {
        self.markLibraryStateChanged()
        var snapshot = self.librarySnapshot
        self.contentReconciler.addArtist(artist, libraryArtistId: libraryArtistId, to: &snapshot)
        self.librarySnapshot = snapshot
    }

    func addToLibrarySet(artistId: String) {
        self.markLibraryStateChanged()
        var snapshot = self.librarySnapshot
        self.contentReconciler.addArtistId(artistId, to: &snapshot)
        self.librarySnapshot = snapshot
    }

    func removeFromLibrarySet(playlistId: String) {
        self.markPlaylistStateChanged(playlistId)
        var snapshot = self.librarySnapshot
        self.contentReconciler.removePlaylistId(playlistId, from: &snapshot)
        self.librarySnapshot = snapshot
    }

    func removeFromLibrary(playlistId: String) {
        self.markPlaylistStateChanged(playlistId)
        var snapshot = self.librarySnapshot
        self.contentReconciler.removePlaylist(playlistId, from: &snapshot)
        self.librarySnapshot = snapshot
    }

    func removeFromLibrary(albumId: String, targetPlaylistId: String? = nil) {
        self.markLibraryStateChanged()
        var snapshot = self.librarySnapshot
        self.contentReconciler.removeAlbum(
            albumId: albumId,
            targetPlaylistId: targetPlaylistId,
            from: &snapshot
        )
        self.librarySnapshot = snapshot
    }

    func removeFromLibrary(podcastId: String) {
        self.markLibraryStateChanged()
        var snapshot = self.librarySnapshot
        self.contentReconciler.removePodcast(podcastId, from: &snapshot)
        self.librarySnapshot = snapshot
    }

    func removeFromLibrarySet(podcastId: String) {
        self.markLibraryStateChanged()
        var snapshot = self.librarySnapshot
        self.contentReconciler.removePodcastId(podcastId, from: &snapshot)
        self.librarySnapshot = snapshot
    }

    func removeFromLibrary(artistId: String) {
        self.markLibraryStateChanged()
        var snapshot = self.librarySnapshot
        self.contentReconciler.removeArtist(artistId, from: &snapshot)
        self.librarySnapshot = snapshot
    }

    func removeFromLibrarySet(artistId: String) {
        self.markLibraryStateChanged()
        var snapshot = self.librarySnapshot
        self.contentReconciler.removeArtistId(artistId, from: &snapshot)
        self.librarySnapshot = snapshot
    }

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
                "Loaded \(content.playlists.count) playlists, \(content.albums.count) albums, \(content.artists.count) artists, and \(content.podcastShows.count) podcasts"
            )

            if self.needsReloadAfterCurrentLoad {
                self.needsReloadAfterCurrentLoad = false
                self.loadingState = self.hasLibrarySnapshot ? .loadingMore : .idle
                await self.load()
            }
        } catch is CancellationError {
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
